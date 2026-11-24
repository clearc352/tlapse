// 经真实 socket 校验字节响应，二进制媒体不转换为 UTF-8。
static NSDictionary *TLFileCall(uint16_t port, NSString *method, NSString *path, NSString *range, BOOL authorized) {
    NSString *request = [NSString stringWithFormat:@"%@ %@ HTTP/1.1\r\nHost: 127.0.0.1:%u\r\n%@%@Connection: close\r\n\r\n", method, path, port,
                         authorized ? @"Authorization: Bearer correct-horse-battery\r\n" : @"",
                         range ? [NSString stringWithFormat:@"Range: %@\r\n", range] : @""];
    NSData *data = TLRawHTTPData(port, request);
    if (!data) { return @{}; }
    NSRange split = [data rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4] options:0 range:NSMakeRange(0, data.length)];
    if (split.location == NSNotFound) { return @{}; }
    NSString *headers = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, split.location)] encoding:NSUTF8StringEncoding];
    NSData *body = [data subdataWithRange:NSMakeRange(NSMaxRange(split), data.length - NSMaxRange(split))];
    return @{@"head": headers ?: @"", @"body": body};
}

static int TLDescriptorCount(void) {
    int count = 0;
    for (int fd = 0; fd < getdtablesize(); fd++) { if (fcntl(fd, F_GETFD) >= 0) { count++; } }
    return count;
}

static int TLStartVideoRequest(uint16_t port, NSString *url) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = TLIPv4("127.0.0.1"); address.sin_port = htons(port);
    struct timeval timeout = {5, 0}; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) { close(fd); return -1; }
    NSString *request = [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: 127.0.0.1:%u\r\nAuthorization: Bearer correct-horse-battery\r\n\r\n", url, port];
    write(fd, request.UTF8String, strlen(request.UTF8String));
    return fd;
}

static void TLTestWebFiles(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *web = [root stringByAppendingPathComponent:@"web"];
    [fm createDirectoryAtPath:[web stringByAppendingPathComponent:@"assets"] withIntermediateDirectories:YES attributes:nil error:nil];
    [@"<title>same-root</title>" writeToFile:[web stringByAppendingPathComponent:@"index.html"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSDictionary *assets = @{@"app.js": @"text/javascript", @"app.css": @"text/css", @"icon.svg": @"image/svg+xml", @"font.woff": @"font/woff", @"font.woff2": @"font/woff2"};
    for (NSString *name in assets) { [@"asset" writeToFile:[web stringByAppendingPathComponent:[@"assets" stringByAppendingPathComponent:name]] atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
    NSDictionary *documents = @{@"MiSans-License.pdf": @"%PDF-1.4\nfixture\n%%EOF\n", @"THIRD-PARTY-LICENSES.txt": @"字体许可\nCopyright fixture\n"};
    NSDictionary *documentTypes = @{@"MiSans-License.pdf": @"application/pdf", @"THIRD-PARTY-LICENSES.txt": @"text/plain; charset=utf-8"};
    for (NSString *name in documents) { [documents[name] writeToFile:[web stringByAppendingPathComponent:name] atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
    NSString *outside = [root stringByAppendingPathComponent:@"private.js"];
    [@"private" writeToFile:outside atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"private" writeToFile:[root stringByAppendingPathComponent:@"private.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"private" writeToFile:[web stringByAppendingPathComponent:@"unknown.bin"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [@"private" writeToFile:[web stringByAppendingPathComponent:@".hidden.pdf"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [fm createSymbolicLinkAtPath:[web stringByAppendingPathComponent:@"escape.js"] withDestinationPath:outside error:nil];
    [fm createSymbolicLinkAtPath:[web stringByAppendingPathComponent:@"escape.pdf"] withDestinationPath:outside error:nil];
    [fm createSymbolicLinkAtPath:[web stringByAppendingPathComponent:@"escape.txt"] withDestinationPath:outside error:nil];
    [fm createSymbolicLinkAtPath:[web stringByAppendingPathComponent:@"linked"] withDestinationPath:root error:nil];
    TLConfig *config = [TLConfig configWithDictionary:@{@"server": @{@"token": @"correct-horse-battery"}, @"projects": @[@{@"id": @"plant", @"name": @"测试"}]} error:nil];
    // 仅夹具绕过生产 storageRoot 配置约束，数据全部位于系统临时目录。
    [config setValue:root forKey:@"storageRoot"];
    TLState *state = [[TLState alloc] initWithPath:[root stringByAppendingPathComponent:@"state.json"]];
    TLWebServer *server = [[TLWebServer alloc] initWithConfigPath:[root stringByAppendingPathComponent:@"config.json"] state:state snap:nil];
    server.indexFileOverride = [web stringByAppendingPathComponent:@"index.html"];
    EXPECT([server startLoopbackForTests:config error:nil], "file server starts");
    uint16_t port = server.port;
    NSDictionary *index = TLFileCall(port, @"GET", @"/", nil, NO);
    EXPECT([index[@"head"] containsString:@"script-src 'self'"] && [index[@"head"] containsString:@"font-src 'self'"] && ![index[@"head"] containsString:@"script-src 'unsafe-inline'"], "same-origin CSP with local fonts");
    NSDictionary *head = TLFileCall(port, @"HEAD", @"/", nil, NO);
    EXPECT([head[@"body"] length] == 0 && [head[@"head"] containsString:@" 200 "], "static HEAD has no body");
    for (NSString *name in assets) {
        NSDictionary *r = TLFileCall(port, @"GET", [@"/assets/" stringByAppendingString:name], nil, NO);
        EXPECT([r[@"head"] containsString:assets[name]] && [r[@"body"] length] == 5, "asset MIME and public access");
    }
    for (NSString *name in documents) {
        NSString *path = [@"/" stringByAppendingString:name];
        NSData *expected = [documents[name] dataUsingEncoding:NSUTF8StringEncoding];
        NSString *type = [@"Content-Type: " stringByAppendingString:documentTypes[name]];
        NSString *length = [NSString stringWithFormat:@"Content-Length: %lu", (unsigned long)expected.length];
        NSDictionary *r = TLFileCall(port, @"GET", path, nil, NO);
        EXPECT([r[@"head"] containsString:@" 200 "] && [r[@"head"] containsString:type] && [r[@"body"] isEqualToData:expected], "public license GET has exact MIME and bytes");
        r = TLFileCall(port, @"HEAD", path, nil, NO);
        EXPECT([r[@"head"] containsString:@" 200 "] && [r[@"head"] containsString:type] && [r[@"head"] containsString:length] && [r[@"body"] length] == 0, "public license HEAD has byte length without body");
        EXPECT([TLFileCall(port, @"POST", path, nil, NO)[@"head"] containsString:@" 405 "], "license static mutations rejected");
    }
    for (NSString *path in @[@"/assets/missing.js", @"/assets/", @"/.hidden.js", @"/%2e%2e/private.js", @"/escape.js", @"/linked/private.js", @"/unknown", @"/config.json"]) {
        EXPECT([TLFileCall(port, @"GET", path, nil, NO)[@"head"] containsString:@" 404 "], "invalid or escaping asset is 404");
    }
    for (NSString *path in @[@"/unknown.bin", @"/.hidden.pdf", @"/escape.pdf", @"/escape.txt", @"/linked/private.txt", @"/%2e%2e/private.txt", @"/missing.pdf"]) {
        for (NSString *method in @[@"GET", @"HEAD"]) {
            EXPECT([TLFileCall(port, method, path, nil, NO)[@"head"] containsString:@" 404 "], "document types do not widen file boundaries");
        }
    }
    EXPECT([TLFileCall(port, @"POST", @"/assets/app.js", nil, NO)[@"head"] containsString:@" 405 "], "static mutations rejected");
    EXPECT([TLFileCall(port, @"GET", @"/api/missing", nil, YES)[@"head"] containsString:@" 404 "], "unknown API never returns HTML");
    server.indexFileOverride = [[web stringByAppendingPathComponent:@"linked"] stringByAppendingPathComponent:@"index.html"];
    EXPECT([TLFileCall(port, @"GET", @"/private.js", nil, NO)[@"head"] containsString:@" 404 "], "symlink resource root rejected");
    server.indexFileOverride = [web stringByAppendingPathComponent:@"index.html"];
    NSString *videoDir = [root stringByAppendingPathComponent:@"projects/plant/videos"];
    [fm createDirectoryAtPath:videoDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableData *video = [NSMutableData dataWithLength:21 * 1024 * 1024 + 13];
    uint8_t *bytes = video.mutableBytes;
    for (NSUInteger i = 0; i < video.length; i++) { bytes[i] = (uint8_t)(i % 251); }
    NSString *videoPath = [videoDir stringByAppendingPathComponent:@"large.mp4"];
    [video writeToFile:videoPath atomically:YES];
    NSString *url = @"/api/projects/plant/media/videos/large.mp4";
    EXPECT([TLFileCall(port, @"GET", url, nil, NO)[@"head"] containsString:@" 401 "], "private video needs authentication");
    NSDictionary *full = TLFileCall(port, @"GET", url, nil, YES);
    EXPECT([full[@"head"] containsString:@" 200 "] && [full[@"body"] isEqualToData:video], "video above 20MiB downloads exactly");
    NSString *lengthHeader = [NSString stringWithFormat:@"Content-Length: %lu", (unsigned long)video.length];
    NSString *rangeHeader = [NSString stringWithFormat:@"Content-Range: bytes */%lu", (unsigned long)video.length];
    head = TLFileCall(port, @"HEAD", url, @"bytes=0-3", YES);
    EXPECT([head[@"body"] length] == 0 && [head[@"head"] containsString:lengthHeader] && [head[@"head"] containsString:@" 200 "], "video HEAD reports full length, ignores Range");
    NSArray *ranges = @[@"bytes=0-3", @"bytes=3-", @"bytes=-17", [NSString stringWithFormat:@"bytes=%lu-999999999", (unsigned long)video.length - 4]];
    NSArray *starts = @[@0, @3, @(video.length - 17), @(video.length - 4)];
    NSArray *lengths = @[@4, @(video.length - 3), @17, @4];
    for (NSUInteger i = 0; i < ranges.count; i++) {
        NSDictionary *r = TLFileCall(port, @"GET", url, ranges[i], YES);
        NSString *expectedRange = [NSString stringWithFormat:@"Content-Range: bytes %llu-%llu/%lu", [starts[i] unsignedLongLongValue], [starts[i] unsignedLongLongValue] + [lengths[i] unsignedLongLongValue] - 1, (unsigned long)video.length];
        NSString *expectedLength = [NSString stringWithFormat:@"Content-Length: %@\r\n", lengths[i]];
        EXPECT([r[@"head"] containsString:expectedRange] && [r[@"head"] containsString:expectedLength], "range has exact Content-Range and Content-Length");
        EXPECT([r[@"head"] containsString:@" 206 "] && [r[@"head"] containsString:@"Accept-Ranges: bytes"] && [r[@"body"] isEqualToData:[video subdataWithRange:NSMakeRange([starts[i] unsignedIntegerValue], [lengths[i] unsignedIntegerValue])]], "range returns correct bytes");
    }
    for (NSString *range in @[@"bytes=999999999-", @"bytes=3-2", @"bytes=-0", @"bytes=", @"bytes=0-1,3-4", @"items=0-1", @"bytes=18446744073709551616-"]) {
        NSDictionary *r = TLFileCall(port, @"GET", url, range, YES);
        EXPECT([r[@"head"] containsString:@" 416 "] && [r[@"head"] containsString:rangeHeader], "invalid range is 416 with total size");
    }
    NSString *photos = [root stringByAppendingPathComponent:@"projects/plant/frames/20261115"];
    [fm createDirectoryAtPath:photos withIntermediateDirectories:YES attributes:nil error:nil];
    [video writeToFile:[photos stringByAppendingPathComponent:@"120000.jpg"] atomically:YES];
    EXPECT([TLFileCall(port, @"GET", @"/api/projects/plant/media/frames/20261115/120000.jpg", nil, YES)[@"head"] containsString:@" 413 "], "photos retain 20MiB limit");
    [fm createSymbolicLinkAtPath:[videoDir stringByAppendingPathComponent:@"escape.mp4"] withDestinationPath:outside error:nil];
    EXPECT([TLFileCall(port, @"GET", @"/api/projects/plant/media/videos/escape.mp4", nil, YES)[@"head"] containsString:@" 404 "], "media symlink rejected");
    int before = TLDescriptorCount();
    for (int i = 0; i < 16; i++) {
        int fd = TLStartVideoRequest(port, url);
        uint8_t chunk[1024]; read(fd, chunk, sizeof(chunk));
        struct linger reset = {1, 0}; setsockopt(fd, SOL_SOCKET, SO_LINGER, &reset, sizeof(reset)); close(fd);
    }
    usleep(150000);
    EXPECT(TLDescriptorCount() == before, "disconnected video transfers release descriptors");
    EXPECT([TLFileCall(port, @"GET", @"/api/status", nil, YES)[@"head"] containsString:@" 200 "], "disconnect releases connection slots");
    // 传输已开始后截断文件，服务应结束不完整响应，释放句柄而不空转。
    int fd = TLStartVideoRequest(port, url);
    uint8_t chunk[4096]; ssize_t count = read(fd, chunk, sizeof(chunk));
    EXPECT(count > 0, "truncation begins after response headers");
    truncate(videoPath.fileSystemRepresentation, 0);
    NSUInteger received = count > 0 ? (NSUInteger)count : 0;
    while ((count = read(fd, chunk, sizeof(chunk))) > 0) { received += (NSUInteger)count; }
    close(fd); usleep(50000);
    EXPECT(received < video.length, "truncation closes incomplete body");
    EXPECT(TLDescriptorCount() == before, "truncated transfer releases descriptors");
    NSString *content = @"/api/projects/plant/content";
    NSString *cookie = TLSessionCookie(TLWebCall(port, @"POST", @"/api/login", @"{\"token\":\"correct-horse-battery\"}", nil, YES));
    EXPECT([TLWebCall(port, @"DELETE", content, nil, cookie, NO) containsString:@" 403 "], "content deletion needs mutation header");
    EXPECT([TLWebCall(port, @"DELETE", @"/api/projects/%2e%2e/content", nil, cookie, YES) containsString:@" 404 "], "content deletion rejects traversal");
    NSString *projectDir = [root stringByAppendingPathComponent:@"projects/plant"];
    NSString *detached = [root stringByAppendingPathComponent:@"detached"];
    EXPECT([fm moveItemAtPath:projectDir toPath:detached error:nil], "move project outside projects directory");
    EXPECT([fm createSymbolicLinkAtPath:projectDir withDestinationPath:detached error:nil], "symlink project outside projects directory");
    EXPECT([TLWebCall(port, @"DELETE", content, nil, cookie, YES) containsString:@" 500 "], "content deletion refuses symlinked project directory");
    EXPECT([fm fileExistsAtPath:[detached stringByAppendingPathComponent:@"videos/large.mp4"]], "symlinked project remains intact");
    [fm removeItemAtPath:projectDir error:nil];
    EXPECT([fm moveItemAtPath:detached toPath:projectDir error:nil], "restore project directory");
    NSString *thumbs = [projectDir stringByAppendingPathComponent:@"thumbs"];
    [fm createDirectoryAtPath:thumbs withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createSymbolicLinkAtPath:[thumbs stringByAppendingPathComponent:@"linked"] withDestinationPath:web error:nil];
    NSString *keep = [projectDir stringByAppendingPathComponent:@"keep.txt"];
    [@"keep" writeToFile:keep atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [state updateProject:@"plant" values:@{TLStateFrameCount: @1, TLStateLastFile: @"projects/plant/frames/20261115/120000.jpg",
                                         TLStateLastEncodeFile: @"projects/plant/videos/large.mp4"} error:nil];
    int mediaLock = TLTryLockProjectMedia(root, NO);
    EXPECT(mediaLock >= 0, "manual command can claim shared media lock");
    EXPECT([TLWebCall(port, @"DELETE", content, nil, cookie, YES) containsString:@" 409 "], "active manual command blocks content deletion");
    if (mediaLock >= 0) { close(mediaLock); }
    EXPECT([TLWebCall(port, @"DELETE", content, nil, cookie, YES) containsString:@" 200 "], "delete paused project content");
    for (NSString *kind in @[@"frames", @"thumbs", @"videos"]) {
        EXPECT(![fm fileExistsAtPath:[projectDir stringByAppendingPathComponent:kind]], "media directory is gone");
    }
    EXPECT([fm fileExistsAtPath:keep] && [fm fileExistsAtPath:outside] && [fm fileExistsAtPath:server.indexFileOverride], "non-media files and symlink targets are preserved");
    EXPECT([state integerForProject:@"plant" key:TLStateFrameCount] == 0 &&
           [state stringForProject:@"plant" key:TLStateLastFile].length == 0 &&
           [state stringForProject:@"plant" key:TLStateLastEncodeFile].length == 0, "media state is reset");
    EXPECT([TLWebCall(port, @"GET", @"/api/projects/plant/frames", nil, cookie, NO) containsString:@" 200 "], "project remains configured");
    EXPECT([TLWebCall(port, @"DELETE", content, nil, cookie, YES) containsString:@" 200 "], "empty project content can be deleted again");
    [server stop];
}
