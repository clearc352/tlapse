#import <Foundation/Foundation.h>

#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <string.h>
#import <syslog.h>
#import <sys/sysctl.h>
#import <unistd.h>

// mediaserverd revokes the camera when a client is not a foreground app.
// Injected only into mediaserverd. Only /usr/local/bin/tlapsed is treated
// as foreground. Every other client keeps the system decision.

#define TL_PATH_MAX 4096
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

static const unsigned int TLBKSForeground = (1u << 3) | (1u << 5);

static void TLNote(const char *text) {
    if (!text) {
        return;
    }
    syslog(LOG_NOTICE, "tlapse-camera: %s", text);
    static const char *const paths[] = {
        "/tmp/tlapse-camera.log",
        "/var/tmp/tlapse-camera.log",
        "/var/mobile/Timelapse/logs/camera-fix-hook.log",
        NULL
    };
    for (int index = 0; paths[index]; index++) {
        FILE *file = fopen(paths[index], "a");
        if (!file) {
            continue;
        }
        fprintf(file, "%s\n", text);
        fclose(file);
    }
}

static void TLPublish(const char *name, int pid) {
    int token = 0;
    if (notify_register_check(name, &token) == NOTIFY_STATUS_OK) {
        notify_set_state(token, (uint64_t)pid);
        notify_cancel(token);
    }
    notify_post(name);
    static const char *const dirs[] = {
        "/tmp/tlapse-camera.",
        "/var/tmp/tlapse-camera.",
        "/var/mobile/Timelapse/logs/camera-fix.",
        NULL
    };
    const char *suffix = strrchr(name, '.');
    if (!suffix || strcmp(suffix, ".loaded") == 0) {
        suffix = "loaded";
    } else if (strcmp(suffix, ".ready") == 0) {
        suffix = "ready";
    } else {
        return;
    }
    for (int index = 0; dirs[index]; index++) {
        char path[128];
        snprintf(path, sizeof(path), "%s%s", dirs[index], suffix);
        FILE *file = fopen(path, "w");
        if (!file) {
            continue;
        }
        fprintf(file, "%d\n", pid);
        fclose(file);
    }
}

static int TLClientPID(id monitor) {
    static const char *const names[] = {"_pid", "pid", "_clientPID", "_processID", NULL};
    Class cls = object_getClass(monitor);
    for (int index = 0; names[index]; index++) {
        Ivar ivar = class_getInstanceVariable(cls, names[index]);
        if (!ivar) {
            continue;
        }
        const char *encoding = ivar_getTypeEncoding(ivar);
        if (!encoding || encoding[0] != 'i') {
            continue;
        }
        int pid = *(int *)((uintptr_t)monitor + (uintptr_t)ivar_getOffset(ivar));
        if (pid > 0) {
            return pid;
        }
    }
    return -1;
}

static void TLCopyText(char *dest, size_t size, const char *source) {
    if (size == 0) {
        return;
    }
    if (!source) {
        dest[0] = 0;
        return;
    }
    size_t length = strlen(source);
    if (length >= size) {
        length = size - 1;
    }
    memcpy(dest, source, length);
    dest[length] = 0;
}

static void TLApplicationID(id monitor, char *dest, size_t size) {
    dest[0] = 0;
    SEL selector = sel_registerName("applicationID");
    Method method = class_getInstanceMethod(object_getClass(monitor), selector);
    if (!method) {
        return;
    }
    const char *encoding = method_getTypeEncoding(method);
    if (!encoding || encoding[0] != '@') {
        return;
    }
    @autoreleasepool {
        id value = ((id (*)(id, SEL))objc_msgSend)(monitor, selector);
        if (![value isKindOfClass:[NSString class]]) {
            return;
        }
        TLCopyText(dest, size, [(NSString *)value UTF8String]);
    }
}

static void TLClientComm(int pid, char *dest, size_t size) {
    if (size == 0) {
        return;
    }
    dest[0] = 0;
    if (pid <= 0) {
        return;
    }
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
    struct kinfo_proc info;
    memset(&info, 0, sizeof(info));
    size_t length = sizeof(info);
    if (sysctl(mib, 4, &info, &length, NULL, 0) != 0) {
        return;
    }
    char comm[17];
    memcpy(comm, info.kp_proc.p_comm, 16);
    comm[16] = 0;
    TLCopyText(dest, size, comm);
}

typedef struct {
    int pid;
    char path[192];
    char comm[20];
    char app[160];
} TLIdentity;

static void TLIdentify(id monitor, TLIdentity *identity) {
    memset(identity, 0, sizeof(*identity));
    identity->pid = TLClientPID(monitor);
    if (identity->pid > 0) {
        char full[TL_PATH_MAX];
        full[0] = 0;
        if (proc_pidpath(identity->pid, full, sizeof(full)) > 0) {
            TLCopyText(identity->path, sizeof(identity->path), full);
        }
        TLClientComm(identity->pid, identity->comm, sizeof(identity->comm));
    }
    TLApplicationID(monitor, identity->app, sizeof(identity->app));
}

static BOOL TLMatchText(const char *text) {
    if (!text || !text[0]) {
        return NO;
    }
    if (strcmp(text, "tlapsed") == 0 || strcmp(text, "/usr/local/bin/tlapsed") == 0) {
        return YES;
    }
    return strstr(text, "/tlapsed") != NULL;
}

static BOOL TLIsTlapse(const TLIdentity *identity) {
    if (strcmp(identity->comm, "tlapsed") == 0) {
        return YES;
    }
    if (TLMatchText(identity->path) || TLMatchText(identity->app)) {
        return YES;
    }
    return NO;
}

static void TLFormat(const TLIdentity *identity, char *dest, size_t size) {
    snprintf(dest, size, "pid=%d comm=%s app=%s path=%s",
             identity->pid, identity->comm, identity->app, identity->path);
}

static void TLSetIvar(id object, const char *name, int value) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (!ivar) {
        return;
    }
    const char *encoding = ivar_getTypeEncoding(ivar);
    if (!encoding) {
        return;
    }
    char *slot = (char *)(uintptr_t)object + ivar_getOffset(ivar);
    if (encoding[0] == 'i') {
        *(int *)slot = value;
    } else if (encoding[0] == 'I') {
        *(unsigned int *)slot = (unsigned int)value;
    } else if (encoding[0] == 'c' || encoding[0] == 'B') {
        *slot = (char)(value ? 1 : 0);
    }
}

static void TLForceForeground(id monitor, int applicationState) {
    if (applicationState > 0) {
        TLSetIvar(monitor, "_applicationState", applicationState);
    }
    TLSetIvar(monitor, "_bksApplicationState", 8);
    TLSetIvar(monitor, "_bksApplicationStateInitialized", 1);
}

static int TLMappedForeground(id monitor) {
    static int cached = -2;
    if (cached != -2) {
        return cached;
    }
    Class cls = objc_getClass("FigCaptureClientSessionMonitor");
    SEL mapper = sel_registerName("_applicationStateForBKSApplicationState:clientType:applicationID:");
    Method method = class_getClassMethod(cls, mapper);
    const char *encoding = method ? method_getTypeEncoding(method) : NULL;
    if (!encoding || (encoding[0] != 'i' && encoding[0] != 'q' && encoding[0] != 'I')) {
        char buffer[192];
        snprintf(buffer, sizeof(buffer), "无法映射前台状态 类型 %s", encoding ? encoding : "无");
        TLNote(buffer);
        cached = -1;
        return cached;
    }
    int clientType = 0;
    SEL typeSelector = sel_registerName("clientType");
    Method typeMethod = class_getInstanceMethod(object_getClass(monitor), typeSelector);
    const char *typeEncoding = typeMethod ? method_getTypeEncoding(typeMethod) : NULL;
    if (typeEncoding && typeEncoding[0] == 'i') {
        clientType = ((int (*)(id, SEL))objc_msgSend)(monitor, typeSelector);
    }
    char app[160];
    TLApplicationID(monitor, app, sizeof(app));
    @autoreleasepool {
        NSString *applicationID = app[0] ? [NSString stringWithUTF8String:app] : nil;
        cached = ((int (*)(id, SEL, unsigned int, int, id))objc_msgSend)(cls, mapper, 8, clientType, applicationID);
    }
    char buffer[192];
    snprintf(buffer, sizeof(buffer), "前台状态映射 %d clientType %d", cached, clientType);
    TLNote(buffer);
    return cached;
}

typedef void (*TLUpdateIMP)(id, SEL, void *, void *);
static TLUpdateIMP TLUpdateOriginal;

static void TLUpdateHook(id self, SEL cmd, void *condition, void *value) {
    TLIdentity identity;
    TLIdentify(self, &identity);
    if (TLIsTlapse(&identity)) {
        static int logged = 0;
        if (logged < 40) {
            logged += 1;
            char who[420];
            char buffer[512];
            TLFormat(&identity, who, sizeof(who));
            snprintf(buffer, sizeof(buffer), "放行 tlapsed，不写入后台条件 %s", who);
            TLNote(buffer);
        }
        TLForceForeground(self, TLMappedForeground(self));
        return;
    }
    static int others = 0;
    if (others < 16) {
        others += 1;
        char who[420];
        char buffer[512];
        TLFormat(&identity, who, sizeof(who));
        snprintf(buffer, sizeof(buffer), "其他客户端条件更新 %s", who);
        TLNote(buffer);
    }
    if (TLUpdateOriginal) {
        TLUpdateOriginal(self, cmd, condition, value);
    }
}

typedef int (*TLResolveIMP)(id, SEL);
static TLResolveIMP TLResolveOriginal;

static int TLResolveHook(id self, SEL cmd) {
    int state = TLResolveOriginal ? TLResolveOriginal(self, cmd) : 0;
    TLIdentity identity;
    TLIdentify(self, &identity);
    if (!TLIsTlapse(&identity)) {
        return state;
    }
    int foreground = TLMappedForeground(self);
    static int logged = 0;
    if (logged < 20) {
        logged += 1;
        char who[420];
        char buffer[512];
        TLFormat(&identity, who, sizeof(who));
        snprintf(buffer, sizeof(buffer), "tlapsed 状态 %d -> %d %s", state, foreground, who);
        TLNote(buffer);
    }
    if (foreground > 0) {
        TLForceForeground(self, foreground);
        return foreground;
    }
    return state;
}

typedef void (*TLHandleIMP)(id, SEL, unsigned int);
static TLHandleIMP TLHandleOriginal;

static void TLHandleHook(id self, SEL cmd, unsigned int state) {
    TLIdentity identity;
    TLIdentify(self, &identity);
    if (TLIsTlapse(&identity) && (state & TLBKSForeground) == 0) {
        static int logged = 0;
        if (logged < 20) {
            logged += 1;
            char buffer[192];
            snprintf(buffer, sizeof(buffer), "忽略 tlapsed 的非前台状态 %u", state);
            TLNote(buffer);
        }
        TLForceForeground(self, TLMappedForeground(self));
        return;
    }
    if (TLHandleOriginal) {
        TLHandleOriginal(self, cmd, state);
    }
}

static BOOL TLSwap(Class monitor, SEL selector, const char *returns, IMP replacement, IMP *original) {
    Method method = class_getInstanceMethod(monitor, selector);
    if (!method) {
        char buffer[192];
        snprintf(buffer, sizeof(buffer), "没有方法 %s", sel_getName(selector));
        TLNote(buffer);
        return NO;
    }
    const char *encoding = method_getTypeEncoding(method);
    char buffer[256];
    snprintf(buffer, sizeof(buffer), "方法 %s 类型 %s", sel_getName(selector), encoding ? encoding : "?");
    TLNote(buffer);
    if (!encoding || !strchr(returns, encoding[0])) {
        TLNote("类型不符，不挂这个方法");
        return NO;
    }
    *original = method_getImplementation(method);
    method_setImplementation(method, replacement);
    return YES;
}

static void TLDumpMethods(Class monitor) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(monitor, &count);
    unsigned int logged = 0;
    for (unsigned int index = 0; methods && index < count && logged < 60; index++) {
        const char *name = sel_getName(method_getName(methods[index]));
        if (!name) {
            continue;
        }
        if (!strstr(name, "State") && !strstr(name, "pplication") && !strstr(name, "resolve") &&
            !strstr(name, "update") && !strstr(name, "Client") && !strstr(name, "pid")) {
            continue;
        }
        const char *encoding = method_getTypeEncoding(methods[index]);
        syslog(LOG_NOTICE, "tlapse-camera method %s %s", name, encoding ? encoding : "?");
        logged += 1;
    }
    if (methods) {
        free(methods);
    }
    syslog(LOG_NOTICE, "tlapse-camera method dump %u", logged);
}

static BOOL TLInstallHook(void) {
    Class monitor = objc_getClass("FigCaptureClientSessionMonitor");
    if (!monitor) {
        return NO;
    }
    TLDumpMethods(monitor);
    BOOL update = TLSwap(monitor, sel_registerName("_updateClientStateCondition:newValue:"), "v",
                         (IMP)TLUpdateHook, (IMP *)&TLUpdateOriginal);
    BOOL resolve = TLSwap(monitor, sel_registerName("_resolveApplicationState"), "iqIBc",
                          (IMP)TLResolveHook, (IMP *)&TLResolveOriginal);
    TLSwap(monitor, sel_registerName("_handleApplicationStateChange:"), "v",
           (IMP)TLHandleHook, (IMP *)&TLHandleOriginal);
    if (!update && !resolve) {
        TLNote("没有挂上任何状态方法");
        return NO;
    }
    TLPublish("com.ddxyl.tlapse.camera.ready", getpid());
    TLNote("摄像头例外已挂上");
    return YES;
}

static void TLDumpClasses(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0 || count > 200000) {
        return;
    }
    Class *classes = malloc(sizeof(Class) * (size_t)count);
    if (!classes) {
        return;
    }
    count = objc_getClassList(classes, count);
    int logged = 0;
    for (int index = 0; index < count && logged < 40; index++) {
        const char *name = class_getName(classes[index]);
        if (!name) {
            continue;
        }
        if (!strstr(name, "FigCaptureClient") && !strstr(name, "SessionMonitor")) {
            continue;
        }
        syslog(LOG_NOTICE, "tlapse-camera class %s", name);
        logged += 1;
    }
    free(classes);
    syslog(LOG_NOTICE, "tlapse-camera class dump %d", logged);
}

static void *TLInstallThread(void *unused) {
    (void)unused;
    syslog(LOG_NOTICE, "tlapse-camera thread %d", getpid());
    sleep(1);
    for (int attempt = 0; attempt < 30; attempt++) {
        @autoreleasepool {
            if (TLInstallHook()) {
                return NULL;
            }
        }
        sleep(1);
    }
    TLDumpClasses();
    TLNote("没有找到 FigCaptureClientSessionMonitor");
    return NULL;
}

__attribute__((constructor)) static void TLLoad(void) {
    static int started = 0;
    if (!__sync_bool_compare_and_swap(&started, 0, 1)) {
        return;
    }
    int pid = getpid();
    syslog(LOG_NOTICE, "tlapse-camera loaded pid %d", pid);
    TLPublish("com.ddxyl.tlapse.camera.loaded", pid);
    TLNote("动态库已载入");
    pthread_t thread;
    int error = pthread_create(&thread, NULL, TLInstallThread, NULL);
    if (error != 0) {
        syslog(LOG_NOTICE, "tlapse-camera pthread %d", error);
        return;
    }
    pthread_detach(thread);
}
