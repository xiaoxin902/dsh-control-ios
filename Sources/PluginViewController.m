#import "PluginViewController.h"

#import "DSHService.h"

@interface PluginViewController ()
@property (nonatomic, copy) NSArray<NSDictionary *> *installed;
@property (nonatomic, copy) NSArray<NSDictionary *> *available;
@property (nonatomic, copy, nullable) NSString *statusLine;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, assign) BOOL busy;
@end

@implementation PluginViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"插件";
    self.tableView.tableFooterView = [UIView new];
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self
                                                      action:@selector(dismissSelf)];
    self.navigationItem.leftBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self
                                                      action:@selector(refreshTapped)];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    [self.spinner startAnimating];
    [self reloadList];
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

// MARK: - 与守护进程通信

/// 发一条命令并等结果；超时返回 nil。阻塞，调用方要在后台线程。
- (nullable NSDictionary *)sendCommand:(NSString *)command target:(nullable NSString *)target timeout:(NSTimeInterval)timeout {
    NSTimeInterval since = NSDate.date.timeIntervalSince1970;
    if (![DSHService requestControlCommand:command target:target]) {
        return nil;
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (NSDate.date < deadline) {
        NSDictionary *result = [DSHService controlResultNewerThan:since];
        if (result) {
            [DSHService removeControlRequest];
            return result;
        }
        usleep(300 * 1000);
    }
    [DSHService removeControlRequest];
    return nil;
}

- (void)reloadList {
    if (self.busy) {
        return;
    }
    self.busy = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = [weakSelf sendCommand:@"plugin-list" target:nil timeout:12];
        dispatch_async(dispatch_get_main_queue(), ^{
            PluginViewController *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            strongSelf.busy = NO;
            [strongSelf.spinner stopAnimating];
            strongSelf.installed = [result[@"installed"] isKindOfClass:NSArray.class] ? result[@"installed"] : @[];
            strongSelf.available = [result[@"available"] isKindOfClass:NSArray.class] ? result[@"available"] : @[];
            if (!result) {
                strongSelf.statusLine = @"控制守护进程没有回应（检查插件安装有没有装好）";
            } else if (![result[@"ok"] boolValue]) {
                strongSelf.statusLine = result[@"message"] ?: @"读取失败";
            } else {
                strongSelf.statusLine = [NSString stringWithFormat:@"已安装 %lu 个，可安装 %lu 个",
                                                                   (unsigned long)strongSelf.installed.count,
                                                                   (unsigned long)strongSelf.available.count];
            }
            [strongSelf.tableView reloadData];
        });
    });
}

- (void)performCommand:(NSString *)command target:(NSString *)target title:(NSString *)title {
    if (self.busy) {
        return;
    }
    self.busy = YES;
    [self.spinner startAnimating];
    UIAlertController *progress = [UIAlertController alertControllerWithTitle:title
                                                                    message:@"正在执行，请稍候…"
                                                             preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:progress animated:YES completion:nil];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *result = [weakSelf sendCommand:command target:target timeout:240];
        dispatch_async(dispatch_get_main_queue(), ^{
            PluginViewController *strongSelf = weakSelf;
            if (!strongSelf) {
                return;
            }
            strongSelf.busy = NO;
            [strongSelf.spinner stopAnimating];
            [progress dismissViewControllerAnimated:YES completion:^{
                BOOL ok = [result[@"ok"] boolValue];
                NSString *message = result[@"message"] ?: (result ? @"未知结果" : @"守护进程没有回应");
                NSString *output = result[@"output"];
                if (!ok && output.length > 0) {
                    message = [message stringByAppendingFormat:@"\n\n%@", output];
                }
                [strongSelf showAlertWithTitle:ok ? @"完成" : @"失败" message:message];
                [strongSelf reloadList];
            }];
        });
    });
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)refreshTapped {
    [self.spinner startAnimating];
    [self reloadList];
}

// MARK: - 表格

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 2;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"已安装" : @"可安装（~/Documents/dsh-plugins 里的 .tgz）";
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 0) {
        return @"安装/移除后要重启 dsh 才会加载。左滑可移除已安装插件。";
    }
    return self.statusLine;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    NSArray *rows = section == 0 ? self.installed : self.available;
    return MAX(rows.count, 1);
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    NSArray<NSDictionary *> *rows = indexPath.section == 0 ? self.installed : self.available;
    if (rows.count == 0) {
        cell.textLabel.text = indexPath.section == 0 ? @"还没有装插件" : @"没有找到 .tgz";
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    NSDictionary *row = rows[indexPath.row];
    if (indexPath.section == 0) {
        NSString *title = row[@"title"] ?: row[@"name"];
        cell.textLabel.text = title;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@  %@", row[@"name"] ?: @"", row[@"version"] ?: @""];
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    } else {
        cell.textLabel.text = row[@"name"];
        double bytes = [row[@"size"] doubleValue];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"点一下安装 · %.0f KB", bytes / 1024.0];
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSArray<NSDictionary *> *rows = indexPath.section == 0 ? self.installed : self.available;
    if (rows.count == 0) {
        return;
    }
    NSDictionary *row = rows[indexPath.row];
    if (indexPath.section == 1) {
        NSString *path = row[@"path"];
        if (path.length == 0) {
            return;
        }
        [self performCommand:@"plugin-install" target:path title:row[@"name"] ?: path];
    }
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath API_AVAILABLE(ios(11.0)) {
    if (indexPath.section != 0 || self.installed.count == 0) {
        return nil;
    }
    NSDictionary *row = self.installed[indexPath.row];
    NSString *name = row[@"name"];
    UISwipeActionsConfiguration *config = nil;
    if (name.length > 0) {
        UIContextualAction *remove =
            [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                    title:@"移除"
                                                  handler:^(UIContextualAction *action, UIView *view, void (^done)(BOOL)) {
                                                      (void)action;
                                                      (void)view;
                                                      done(YES);
                                                      [self performCommand:@"plugin-remove" target:name title:name];
                                                  }];
        config = [UISwipeActionsConfiguration configurationWithActions:@[ remove ]];
    }
    return config;
}

@end
