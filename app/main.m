#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <ImageIO/ImageIO.h>
#import "TLClient.h"

static NSString *const TLDefaultAddress = @"127.0.0.1:8080";
static NSString *const TLAddressKey = @"serverAddress";

@interface TLAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic) UIWindow *window;
@property (nonatomic) TLClient *client;
- (void)showLoginWithMessage:(NSString *)message;
- (void)showProjectsWithClient:(TLClient *)client;
@end

static TLAppDelegate *TLApp(void);
static UIBarButtonItem *TLButton(NSString *title, id target, SEL action);
static UITableViewCell *TLCell(UITableView *table, NSString *title, NSString *subtitle, BOOL opens);

@interface TLTableController : UITableViewController
@property (nonatomic, readonly) TLClient *client;
@property (nonatomic, getter=isBusy) BOOL busy;
- (instancetype)initWithClient:(TLClient *)client title:(NSString *)title;
- (void)perform:(NSString *)method path:(NSString *)path body:(NSDictionary *)body
        timeout:(NSTimeInterval)timeout reply:(void (^)(NSDictionary *payload))reply;
- (void)showMessage:(NSString *)message;
- (void)confirm:(NSString *)title message:(NSString *)message action:(dispatch_block_t)action;
@end

@interface TLPhotoController : UIViewController
@property (nonatomic) TLClient *client;
@property (nonatomic, copy) NSString *path;
@end

@implementation TLPhotoController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    UIImageView *imageView = [[UIImageView alloc] init];
    imageView.contentMode = UIViewContentModeScaleAspectFit;
    imageView.accessibilityLabel = self.title;
    imageView.isAccessibilityElement = YES;
    UILabel *status = [[UILabel alloc] init];
    status.text = @"正在读取照片…";
    status.textColor = UIColor.whiteColor;
    status.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    status.adjustsFontForContentSizeCategory = YES;
    status.numberOfLines = 0;
    status.textAlignment = NSTextAlignmentCenter;
    imageView.translatesAutoresizingMaskIntoConstraints = NO;
    status.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:imageView];
    [self.view addSubview:status];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [imageView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [imageView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [imageView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [imageView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [status.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [status.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [status.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:16],
    ]];
    [self.client getMedia:self.path reply:^(NSData *data, NSError *error) {
        if (self.navigationController.topViewController != self || TLApp().client != self.client) return;
        if ([error.domain isEqualToString:TLHTTPErrorDomain] && error.code == 401) {
            [TLApp() showLoginWithMessage:@"会话已过期，请重新登录。"];
            return;
        }
        if (error) {
            status.text = error.code == 404 && [error.domain isEqualToString:TLHTTPErrorDomain]
                ? @"还没有照片，或照片已被移除。" : error.localizedDescription;
            return;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
            NSDictionary *options = @{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                                      (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
                                      (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @2200};
            CGImageRef scaled = source ? CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options) : NULL;
            UIImage *image = scaled ? [UIImage imageWithCGImage:scaled] : nil;
            if (scaled) CGImageRelease(scaled);
            if (source) CFRelease(source);
            dispatch_async(dispatch_get_main_queue(), ^{
                imageView.image = image;
                status.hidden = image != nil;
                if (!image) status.text = @"无法读取此照片。";
            });
        });
    }];
}

@end

typedef NS_ENUM(NSUInteger, TLMediaKind) { TLMediaDates, TLMediaFrames, TLMediaVideos };

@interface TLMediaController : TLTableController
@property (nonatomic) TLMediaKind kind;
@property (nonatomic, copy) NSString *projectPath;
@property (nonatomic, copy) NSString *day;
@property (nonatomic) NSArray *items;
@property (nonatomic) BOOL loaded;
@end

@implementation TLMediaController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(load) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.rightBarButtonItem = TLButton(@"刷新", self, @selector(load));
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self load];
}

- (void)load {
    NSString *path;
    NSString *key;
    if (self.kind == TLMediaVideos) {
        path = @"/videos";
        key = @"videos";
    } else if (self.kind == TLMediaFrames) {
        path = [@"/frames?date=" stringByAppendingString:TLPathSegment(self.day)];
        key = @"frames";
    } else {
        path = @"/frames";
        key = @"dates";
    }
    [self perform:@"GET" path:[self.projectPath stringByAppendingString:path] body:nil timeout:20 reply:^(NSDictionary *payload) {
        self.items = payload[key];
        self.loaded = YES;
        if (self.kind == TLMediaVideos && [payload[@"encodeEnabled"] boolValue]) {
            self.navigationItem.rightBarButtonItems = @[TLButton(@"合成", self, @selector(encode)),
                                                        TLButton(@"刷新", self, @selector(load))];
        }
        [self.tableView reloadData];
    }];
}

- (void)encode {
    [self perform:@"POST" path:[self.projectPath stringByAppendingString:@"/encode"] body:nil timeout:600 reply:^(NSDictionary *payload) {
        [self load];
        [self showMessage:payload[@"message"] ?: @"已合成"];
    }];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.items.count; }

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (!self.loaded) return nil;
    if (!self.items.count) return self.kind == TLMediaVideos ? @"还没有视频。" : @"还没有照片。";
    return self.kind == TLMediaFrames ? @"向左滑动一张照片可删除。" : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    id item = self.items[indexPath.row];
    if (self.kind == TLMediaDates) return TLCell(tableView, item, nil, YES);
    if (self.kind == TLMediaFrames) return TLCell(tableView, item[@"label"] ?: item[@"name"], item[@"name"], YES);
    return TLCell(tableView, item[@"name"], nil, YES);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    id item = self.items[indexPath.row];
    if (self.kind == TLMediaDates) {
        TLMediaController *day = [[TLMediaController alloc] initWithClient:self.client title:item];
        day.kind = TLMediaFrames;
        day.projectPath = self.projectPath;
        day.day = item;
        [self.navigationController pushViewController:day animated:YES];
    } else if (self.kind == TLMediaFrames) {
        TLPhotoController *photo = [[TLPhotoController alloc] init];
        photo.title = item[@"label"] ?: item[@"name"];
        photo.client = self.client;
        photo.path = [NSString stringWithFormat:@"%@/media/frames/%@/%@", self.projectPath, TLPathSegment(self.day), TLPathSegment(item[@"name"])];
        [self.navigationController pushViewController:photo animated:YES];
    } else {
        [self playVideo:item[@"name"]];
    }
}

- (void)playVideo:(NSString *)name {
    NSString *path = [NSString stringWithFormat:@"%@/media/videos/%@", self.projectPath, TLPathSegment(name)];
    NSURL *url = [self.client URLForPath:path];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetHTTPCookiesKey: [self.client cookiesForURL:url]}];
    self.busy = YES;
    [asset loadValuesAsynchronouslyForKeys:@[@"playable"] completionHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            if (TLApp().client != self.client || self.navigationController.topViewController != self) return;
            if ([asset statusOfValueForKey:@"playable" error:NULL] != AVKeyValueStatusLoaded || !asset.playable) {
                [self perform:@"GET" path:@"/api/status" body:nil timeout:20 reply:^(NSDictionary *payload) {
                    [self showMessage:@"无法播放此视频。"];
                }];
                return;
            }
            AVPlayerViewController *player = [[AVPlayerViewController alloc] init];
            player.player = [AVPlayer playerWithPlayerItem:[AVPlayerItem playerItemWithAsset:asset]];
            player.modalPresentationStyle = UIModalPresentationFullScreen;
            [self presentViewController:player animated:YES completion:^{ [player.player play]; }];
        });
    }];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.kind == TLMediaFrames && !self.isBusy;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (![self tableView:tableView canEditRowAtIndexPath:indexPath]) return nil;
    NSString *name = self.items[indexPath.row][@"name"];
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除"
        handler:^(UIContextualAction *action, UIView *view, void (^completion)(BOOL)) {
            completion(YES);
            [self confirm:@"删除照片？" message:name action:^{
                NSString *path = [NSString stringWithFormat:@"%@/frames/%@/%@", self.projectPath, TLPathSegment(self.day), TLPathSegment(name)];
                [self perform:@"DELETE" path:path body:nil timeout:20 reply:^(NSDictionary *payload) { [self load]; }];
            }];
        }];
    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[remove]];
    config.performsFirstActionWithFullSwipe = NO;
    return config;
}

@end

static TLAppDelegate *TLApp(void) {
    return (TLAppDelegate *)UIApplication.sharedApplication.delegate;
}

static NSString *TLTrim(NSString *text) {
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString *TLProjectPath(NSDictionary *project) {
    return [@"/api/projects/" stringByAppendingString:TLPathSegment(project[@"id"])];
}

static UIBarButtonItem *TLButton(NSString *title, id target, SEL action) {
    return [[UIBarButtonItem alloc] initWithTitle:title style:UIBarButtonItemStylePlain target:target action:action];
}

static UITableViewCell *TLCell(UITableView *table, NSString *title, NSString *subtitle, BOOL opens) {
    static NSString *const reuse = @"row";
    UITableViewCell *cell = [table dequeueReusableCellWithIdentifier:reuse];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuse];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.adjustsFontForContentSizeCategory = YES;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    cell.detailTextLabel.adjustsFontForContentSizeCategory = YES;
    cell.detailTextLabel.textColor = UIColor.grayColor;
    cell.detailTextLabel.numberOfLines = 0;
    cell.textLabel.textColor = table.tintColor;
    cell.textLabel.text = title;
    cell.detailTextLabel.text = subtitle;
    cell.accessoryType = opens ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
    return cell;
}

@implementation TLTableController

- (instancetype)initWithClient:(TLClient *)client title:(NSString *)title {
    if ((self = [super initWithStyle:UITableViewStyleGrouped])) {
        _client = client;
        self.title = title;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 52;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
}

- (void)setBusy:(BOOL)busy {
    _busy = busy;
    self.tableView.allowsSelection = !busy;
    self.navigationItem.hidesBackButton = busy;
    for (UIBarButtonItem *item in self.navigationItem.rightBarButtonItems ?: @[]) item.enabled = !busy;
    for (UIBarButtonItem *item in self.navigationItem.leftBarButtonItems ?: @[]) item.enabled = !busy;
    if (busy) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
        [spinner startAnimating];
        self.navigationItem.titleView = spinner;
        spinner.accessibilityLabel = @"正在连接";
    } else {
        self.navigationItem.titleView = nil;
        [self.refreshControl endRefreshing];
    }
}

- (void)perform:(NSString *)method path:(NSString *)path body:(NSDictionary *)body
        timeout:(NSTimeInterval)timeout reply:(void (^)(NSDictionary *payload))reply {
    if (self.isBusy) return;
    self.busy = YES;
    [self.client request:method path:path body:body timeout:timeout reply:^(NSDictionary *payload, NSError *error) {
        self.busy = NO;
        if (TLApp().client != self.client) return;
        if ([error.domain isEqualToString:TLHTTPErrorDomain] && error.code == 401) {
            [TLApp() showLoginWithMessage:@"会话已过期，请重新登录。"];
        } else if (error) {
            [self showMessage:error.localizedDescription];
        } else if (reply) {
            reply(payload);
        }
    }];
}

- (void)showMessage:(NSString *)message {
    if (!self.view.window || self.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirm:(NSString *)title message:(NSString *)message action:(dispatch_block_t)action {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *item) { action(); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

@interface TLLoginController : TLTableController <UITextFieldDelegate>
@property (nonatomic) UITextField *address;
@property (nonatomic) UITextField *password;
@property (nonatomic, copy) NSString *message;
@end

static UITextField *TLField(NSString *label, NSString *placeholder, NSString *value, UIKeyboardType keyboard) {
    UITextField *field = [[UITextField alloc] init];
    field.text = value;
    field.placeholder = placeholder;
    field.accessibilityLabel = label;
    field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    field.adjustsFontForContentSizeCategory = YES;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.keyboardType = keyboard;
    return field;
}

static UITableViewCell *TLFieldCell(UITextField *field) {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:field];
    UILayoutGuide *margins = cell.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [field.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [field.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [field.topAnchor constraintEqualToAnchor:margins.topAnchor],
        [field.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
        [field.heightAnchor constraintGreaterThanOrEqualToConstant:28],
    ]];
    return cell;
}

@implementation TLLoginController

- (void)viewDidLoad {
    [super viewDidLoad];
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:TLAddressKey];
    self.address = TLField(@"服务器地址", TLDefaultAddress, saved ?: TLDefaultAddress, UIKeyboardTypeURL);
    self.address.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.address.autocorrectionType = UITextAutocorrectionTypeNo;
    self.address.returnKeyType = UIReturnKeyNext;
    self.address.delegate = self;
    self.password = TLField(@"控制台口令", @"输入控制台口令", nil, UIKeyboardTypeDefault);
    self.password.secureTextEntry = YES;
    self.password.textContentType = UITextContentTypePassword;
    self.password.returnKeyType = UIReturnKeyGo;
    self.password.delegate = self;
    self.navigationItem.rightBarButtonItem = TLButton(@"登录", self, @selector(login));
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 1; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"服务器地址" : @"控制台口令";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) return @"本机使用 127.0.0.1:8080。连接另一台手机时，请填写它的地址和端口。仅在可信网络使用。";
    return self.message;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    return TLFieldCell(indexPath.section == 0 ? self.address : self.password);
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.address) [self.password becomeFirstResponder];
    else [self login];
    return YES;
}

- (void)login {
    if (self.isBusy) return;
    NSURL *server = [TLClient serverURLForAddress:self.address.text];
    NSString *token = TLTrim(self.password.text);
    [self.view endEditing:YES];
    if (!server || !token.length) {
        [self showMessage:server ? @"请输入控制台口令。" : @"请输入有效的服务器地址，如 127.0.0.1:8080。"];
        return;
    }
    self.busy = YES;
    self.address.enabled = self.password.enabled = NO;
    TLClient *client = [[TLClient alloc] initWithServer:server];
    [client request:@"POST" path:@"/api/login" body:@{@"token": token} timeout:20 reply:^(NSDictionary *payload, NSError *error) {
        self.busy = NO;
        self.address.enabled = self.password.enabled = YES;
        if (error || ![payload[@"ok"] boolValue] || ![client cookiesForURL:server].count) {
            [client invalidate];
            [self showMessage:error.localizedDescription ?: @"服务器未建立登录会话。"];
            return;
        }
        [NSUserDefaults.standardUserDefaults setObject:TLTrim(self.address.text) forKey:TLAddressKey];
        self.password.text = @"";
        [TLApp() showProjectsWithClient:client];
    }];
}

@end

@interface TLFormController : TLTableController
@property (nonatomic) NSDictionary *project;
@property (nonatomic) NSArray<UITextField *> *fields;
@property (nonatomic) UISwitch *shutter;
@end

@implementation TLFormController

- (void)viewDidLoad {
    [super viewDidLoad];
    NSDictionary *capture = self.project[@"capture"];
    NSMutableArray *fields = [NSMutableArray array];
    if (!self.project) {
        UITextField *identifier = TLField(@"项目 ID", @"如 plant", nil, UIKeyboardTypeASCIICapable);
        identifier.autocapitalizationType = UITextAutocapitalizationTypeNone;
        identifier.autocorrectionType = UITextAutocorrectionTypeNo;
        [fields addObject:identifier];
    }
    [fields addObject:TLField(@"名称", @"如 豆苗", self.project[@"name"], UIKeyboardTypeDefault)];
    [fields addObject:TLField(@"拍摄间隔（秒）", @"5–86400", [capture[@"interval"] stringValue] ?: @"300", UIKeyboardTypeNumberPad)];
    UITextField *resolution = TLField(@"分辨率", @"如 1920x1440 或 full", capture[@"resolution"] ?: @"1920x1440", UIKeyboardTypeASCIICapable);
    resolution.autocapitalizationType = UITextAutocapitalizationTypeNone;
    resolution.autocorrectionType = UITextAutocorrectionTypeNo;
    [fields addObject:resolution];
    self.fields = fields;
    self.shutter = [[UISwitch alloc] init];
    self.shutter.accessibilityLabel = @"快门声";
    self.shutter.on = !capture[@"shutterSound"] || [capture[@"shutterSound"] boolValue];
    self.navigationItem.rightBarButtonItem = TLButton(@"保存", self, @selector(save));
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return self.fields.count + 1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 1; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section < self.fields.count ? self.fields[section].accessibilityLabel : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == self.fields.count) return self.project ? @"只保存这里修改的参数。" : @"新项目默认暂停，保存后可手动继续拍摄。";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section < self.fields.count) return TLFieldCell(self.fields[indexPath.section]);
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.text = @"快门声";
    cell.accessoryView = self.shutter;
    return cell;
}

- (void)setBusy:(BOOL)busy {
    [super setBusy:busy];
    for (UITextField *field in self.fields) field.enabled = !busy;
    self.shutter.enabled = !busy;
}

- (void)save {
    [self.view endEditing:YES];
    NSUInteger offset = self.project ? 0 : 1;
    NSString *identifier = offset ? TLTrim(self.fields[0].text) : self.project[@"id"];
    NSString *name = TLTrim(self.fields[offset].text);
    NSString *interval = TLTrim(self.fields[offset + 1].text);
    NSString *resolution = TLTrim(self.fields[offset + 2].text);
    if ([identifier rangeOfString:@"^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$" options:NSRegularExpressionSearch].location == NSNotFound) {
        [self showMessage:@"项目 ID 以英文字母或数字开头，最多 64 位，只能包含字母、数字、下划线和减号。"];
        return;
    }
    if (name.length < 1 || name.length > 80) {
        [self showMessage:@"名称须为 1–80 个字符。"];
        return;
    }
    if ([interval rangeOfString:@"^[0-9]{1,5}$" options:NSRegularExpressionSearch].location == NSNotFound ||
        interval.integerValue < 5 || interval.integerValue > 86400) {
        [self showMessage:@"拍摄间隔须为 5–86400 秒的整数。"];
        return;
    }
    if ([resolution rangeOfString:@"^(full|[0-9]{2,5}x[0-9]{2,5})$" options:NSRegularExpressionSearch].location == NSNotFound) {
        [self showMessage:@"分辨率请输入 full 或宽x高，如 1920x1440。"];
        return;
    }
    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    NSMutableDictionary *capture = [NSMutableDictionary dictionary];
    NSDictionary *original = self.project[@"capture"];
    if (!self.project || ![name isEqual:self.project[@"name"]]) body[@"name"] = name;
    if (!self.project || interval.integerValue != [original[@"interval"] integerValue]) capture[@"interval"] = @(interval.integerValue);
    if (!self.project || ![resolution isEqual:original[@"resolution"]]) capture[@"resolution"] = resolution;
    BOOL shutterWasOn = !original[@"shutterSound"] || [original[@"shutterSound"] boolValue];
    if (!self.project || self.shutter.isOn != shutterWasOn) capture[@"shutterSound"] = @(self.shutter.isOn);
    if (capture.count) body[@"capture"] = capture;
    if (!self.project) body[@"id"] = identifier;
    if (!body.count) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    [self perform:self.project ? @"PUT" : @"POST" path:self.project ? TLProjectPath(self.project) : @"/api/projects"
             body:body timeout:20 reply:^(NSDictionary *payload) {
        [self.navigationController popViewControllerAnimated:YES];
    }];
}

@end

static NSString *TLProjectSummary(NSDictionary *project) {
    return [NSString stringWithFormat:@"%@ · %@ 秒/张 · %@ 张",
        [project[@"enabled"] boolValue] ? @"拍摄中" : @"已暂停", project[@"capture"][@"interval"] ?: @300,
        project[@"state"][@"frameCount"] ?: @0];
}

@interface TLProjectController : TLTableController
@property (nonatomic) NSDictionary *project;
@property (nonatomic) BOOL captureUnavailable;
@end

@implementation TLProjectController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = TLButton(@"刷新", self, @selector(load));
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self load];
}

- (void)load {
    [self perform:@"GET" path:@"/api/projects" body:nil timeout:20 reply:^(NSDictionary *payload) {
        for (NSDictionary *project in payload[@"projects"]) {
            if ([project[@"id"] isEqual:self.project[@"id"]]) {
                self.project = project;
                self.title = project[@"name"];
                [self.tableView reloadData];
                return;
            }
        }
        [self.navigationController popViewControllerAnimated:YES];
    }];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 3; }

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (section == 0) return self.captureUnavailable ? 2 : 3;
    if (section == 1) return 3;
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return @[@"拍摄", @"媒体", @"项目"][section];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section != 0) return nil;
    NSString *state = TLProjectSummary(self.project);
    NSString *error = self.project[@"state"][@"lastError"];
    return error.length ? [NSString stringWithFormat:@"%@\n%@", state, error] : state;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == 0) {
        NSString *toggle = [self.project[@"enabled"] boolValue] ? @"暂停拍摄" : @"继续拍摄";
        NSArray *titles = @[toggle, @"编辑拍摄参数", @"拍一张"];
        NSString *resolution = indexPath.row == 1 ? self.project[@"capture"][@"resolution"] : nil;
        return TLCell(tableView, titles[indexPath.row], resolution, indexPath.row == 1);
    }
    if (indexPath.section == 1) return TLCell(tableView, @[@"最新照片", @"照片库", @"视频"][indexPath.row], nil, YES);
    UITableViewCell *cell = TLCell(tableView, @"删除项目", @"保留已保存的照片和视频", NO);
    cell.textLabel.textColor = [UIColor colorWithRed:0.72 green:0.15 blue:0.17 alpha:1];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *path = TLProjectPath(self.project);
    if (indexPath.section == 0) {
        if (indexPath.row == 1) {
            TLFormController *form = [[TLFormController alloc] initWithClient:self.client title:@"拍摄参数"];
            form.project = self.project;
            [self.navigationController pushViewController:form animated:YES];
        } else {
            NSString *action = indexPath.row == 2 ? @"/snap" : ([self.project[@"enabled"] boolValue] ? @"/pause" : @"/resume");
            [self perform:@"POST" path:[path stringByAppendingString:action] body:nil timeout:indexPath.row == 2 ? 90 : 20
                    reply:^(NSDictionary *payload) {
                [self load];
                if ([action isEqualToString:@"/snap"]) [self showMessage:payload[@"message"] ?: @"已保存照片"];
            }];
        }
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            TLPhotoController *photo = [[TLPhotoController alloc] init];
            photo.title = @"最新照片";
            photo.client = self.client;
            photo.path = [path stringByAppendingString:@"/latest.jpg"];
            [self.navigationController pushViewController:photo animated:YES];
        } else {
            TLMediaController *media = [[TLMediaController alloc] initWithClient:self.client title:indexPath.row == 1 ? @"照片库" : @"视频"];
            media.kind = indexPath.row == 1 ? TLMediaDates : TLMediaVideos;
            media.projectPath = path;
            [self.navigationController pushViewController:media animated:YES];
        }
    } else {
        [self confirm:@"删除项目？" message:@"只删除项目配置，已保存的照片和视频仍保留在设备上。" action:^{
            [self perform:@"DELETE" path:path body:nil timeout:20 reply:^(NSDictionary *payload) {
                [self.navigationController popViewControllerAnimated:YES];
            }];
        }];
    }
}

@end

@interface TLProjectsController : TLTableController
@property (nonatomic) NSArray<NSDictionary *> *projects;
@property (nonatomic) NSDictionary *status;
@property (nonatomic) BOOL loaded;
@end

@implementation TLProjectsController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.refreshControl = [[UIRefreshControl alloc] init];
    [self.refreshControl addTarget:self action:@selector(load) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.leftBarButtonItem = TLButton(@"退出", self, @selector(logout));
    self.navigationItem.rightBarButtonItems = @[TLButton(@"新建", self, @selector(create)), TLButton(@"刷新", self, @selector(load))];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self load];
}

- (void)load {
    [self perform:@"GET" path:@"/api/projects" body:nil timeout:20 reply:^(NSDictionary *payload) {
        self.projects = payload[@"projects"];
        self.loaded = YES;
        [self.tableView reloadData];
        [self perform:@"GET" path:@"/api/status" body:nil timeout:20 reply:^(NSDictionary *status) {
            self.status = status;
            [self.tableView reloadData];
        }];
    }];
}

- (void)logout {
    if (self.isBusy) return;
    TLClient *client = self.client;
    self.busy = YES;
    [client request:@"POST" path:@"/api/logout" body:nil timeout:5 reply:^(NSDictionary *payload, NSError *error) {
        if (TLApp().client != client) return;
        NSString *message = error && !([error.domain isEqualToString:TLHTTPErrorDomain] && error.code == 401)
            ? @"已退出此 App；无法确认服务器已结束会话。" : nil;
        [TLApp() showLoginWithMessage:message];
    }];
}

- (void)create {
    TLFormController *form = [[TLFormController alloc] initWithClient:self.client title:@"新建项目"];
    [self.navigationController pushViewController:form animated:YES];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return self.projects.count; }

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (!self.status) return @"项目";
    NSMutableString *status = [NSMutableString stringWithFormat:@"tlapse %@ · 剩余 %@",
        self.status[@"version"] ?: @"", self.status[@"freeText"] ?: @"未知"];
    if (self.status[@"battery"][@"percent"]) {
        [status appendFormat:@" · 电量 %@%%", self.status[@"battery"][@"percent"]];
    }
    return status;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return self.loaded && !self.projects.count ? @"还没有项目。点「新建」添加一个。" : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *project = self.projects[indexPath.row];
    return TLCell(tableView, project[@"name"], TLProjectSummary(project), YES);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *project = self.projects[indexPath.row];
    TLProjectController *detail = [[TLProjectController alloc] initWithClient:self.client title:project[@"name"]];
    detail.project = project;
    detail.captureUnavailable = [self.status[@"features"][@"capture"] isEqual:@NO];
    [self.navigationController pushViewController:detail animated:YES];
}

@end

@implementation TLAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.tintColor = [UIColor colorWithRed:0.24 green:0.36 blue:0.20 alpha:1];
    [self showLoginWithMessage:nil];
    [self.window makeKeyAndVisible];
    return YES;
}

- (void)showLoginWithMessage:(NSString *)message {
    [self.client invalidate];
    self.client = nil;
    TLLoginController *login = [[TLLoginController alloc] initWithClient:nil title:@"帧轨"];
    login.message = message;
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:login];
}

- (void)showProjectsWithClient:(TLClient *)client {
    self.client = client;
    TLProjectsController *projects = [[TLProjectsController alloc] initWithClient:client title:@"帧轨 · 项目"];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:projects];
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(TLAppDelegate.class));
    }
}
