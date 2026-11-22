// Custom queue
// A queue that lives entirely inside YouMod, so it does not depend on YouTube's own (Premium) queue.
// Videos are stored locally, and when the current video finishes the next one is opened with a
// regular in-app watch command (the same thing a tapped video cell sends).
#import "Headers.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <YouTubeHeader/YTICommand.h>
#import <YouTubeHeader/YTCommandResponderEvent.h>
#import <YouTubeHeader/YTDefaultSheetController.h>
#import <YouTubeHeader/YTAutoplayAutonavController.h>
#import <YouTubeHeader/YTIPlayerResponse.h>
#import <YouTubeHeader/YTPlayerResponse.h>
#import <YouTubeHeader/YTIVideoDetails.h>

@interface YTDefaultSheetController (YouModQueue)
+ (instancetype)sheetControllerWithParentResponder:(id)parentResponder;
- (void)addAction:(YTActionSheetAction *)action;
- (void)presentFromView:(UIView *)view animated:(BOOL)animated completion:(void (^)(void))completion;
- (void)presentFromViewController:(UIViewController *)vc animated:(BOOL)animated completion:(void (^)(void))completion;
@end

@interface YTPlayerViewController (YouModQueue)
- (YTPlayerResponse *)contentPlayerResponse;
@end

@interface YTIVideoDetails (YouModQueue)
- (NSString *)title;
- (NSString *)author;
- (BOOL)isLive;
@end

static NSString *const YouModQueueItemsKey = @"YouModQueueItems";
static NSString *const YouModQueueDidChangeNotification = @"YouModQueueDidChangeNotification";
static NSString *const YouModQueueItemID = @"id";
static NSString *const YouModQueueItemTitle = @"title";
static NSString *const YouModQueueItemAuthor = @"author";

// Seconds before the end of a video at which the queue takes over.
static const CGFloat YouModQueueEndThreshold = 1.0;

static BOOL YouModQueueActive = NO;
static __weak YTPlayerViewController *YouModQueueMainPlayer;
static NSString *YouModQueuePendingVideoID;
static NSString *YouModQueueTrackedVideoID;
static BOOL YouModQueueSawEarlierPosition;
static BOOL YouModQueueFiredForCurrentVideo;
static CGFloat YouModQueueLastTotalTime;
static NSInteger YouModQueueTotalGrowthCount;

void YouModQueuePlayVideoID(NSString *videoID);
void YouModQueuePresent(UIViewController *presenter);

#pragma mark - Helpers

static UIViewController *YouModQueueTopViewController(UIViewController *root) {
    if (!root) {
        UIWindow *keyWindow = nil;
        for (UIWindow *window in UIApplication.sharedApplication.windows) {
            if (window.isKeyWindow) {
                keyWindow = window;
                break;
            }
        }
        if (!keyWindow) keyWindow = UIApplication.sharedApplication.windows.firstObject;
        root = keyWindow.rootViewController;
    }
    while (root.presentedViewController && !root.presentedViewController.isBeingDismissed) root = root.presentedViewController;
    if ([root isKindOfClass:UINavigationController.class] && ((UINavigationController *)root).topViewController)
        return YouModQueueTopViewController(((UINavigationController *)root).topViewController);
    if ([root isKindOfClass:UITabBarController.class] && ((UITabBarController *)root).selectedViewController)
        return YouModQueueTopViewController(((UITabBarController *)root).selectedViewController);
    return root;
}

static void YouModQueueToast(NSString *message) {
    @try {
        id responder = YouModQueueTopViewController(nil);
        if (!responder) return;
        [[%c(YTToastResponderEvent) eventWithMessage:message firstResponder:responder] send];
    } @catch (__unused NSException *exception) {
    }
}

static BOOL YouModQueueIsValidVideoID(NSString *videoID) {
    if (![videoID isKindOfClass:NSString.class] || videoID.length != 11) return NO;
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"] invertedSet];
    return [videoID rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

// Accepts a watch/short/share link or a bare video ID.
static NSString *YouModQueueVideoIDFromText(NSString *text) {
    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (text.length == 0) return nil;
    if (YouModQueueIsValidVideoID(text)) return text;
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"(?:[?&]v=|youtu\\.be/|/shorts/|/live/|/embed/)([A-Za-z0-9_-]{11})(?![A-Za-z0-9_-])" options:0 error:nil];
    });
    NSTextCheckingResult *match = [regex firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!match || match.numberOfRanges < 2) return nil;
    return [text substringWithRange:[match rangeAtIndex:1]];
}

static NSString *YouModQueueVideoIDForPlayer(YTPlayerViewController *player) {
    if (!player) return nil;
    NSString *videoID = [player contentVideoID];
    if (videoID.length == 0) videoID = [player currentVideoID];
    return videoID.length ? videoID : nil;
}

static YTIVideoDetails *YouModQueueVideoDetailsForPlayer(YTPlayerViewController *player) {
    @try {
        if (![player respondsToSelector:@selector(contentPlayerResponse)]) return nil;
        YTPlayerResponse *response = [player contentPlayerResponse];
        if (![response respondsToSelector:@selector(playerData)]) return nil;
        YTIPlayerResponse *playerData = [response playerData];
        if (![playerData respondsToSelector:@selector(videoDetails)]) return nil;
        return playerData.videoDetails;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

// The regular watch player only. Shorts and muted feed previews must never drive the queue.
static BOOL YouModQueueIsMainPlayer(YTPlayerViewController *player) {
    if (!player) return NO;
    if ([player respondsToSelector:@selector(isInlinePlaybackActive)] && [player isInlinePlaybackActive]) return NO;
    for (UIViewController *vc = player.parentViewController; vc; vc = vc.parentViewController) {
        NSString *name = NSStringFromClass(vc.class);
        if ([name containsString:@"Reel"] || [name containsString:@"Shorts"]) return NO;
    }
    return YES;
}

#pragma mark - Storage

@interface YouModQueueManager : NSObject
+ (instancetype)shared;
- (NSArray <NSDictionary *> *)items;
- (NSUInteger)count;
- (NSString *)nextVideoIDExcluding:(NSString *)videoID;
- (BOOL)containsVideoID:(NSString *)videoID;
- (BOOL)addVideoID:(NSString *)videoID title:(NSString *)title author:(NSString *)author atFront:(BOOL)atFront;
- (void)removeItemAtIndex:(NSUInteger)index;
- (void)removeVideoID:(NSString *)videoID;
- (void)moveItemFromIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex;
- (void)clear;
- (void)handleSaveLongPress:(UILongPressGestureRecognizer *)sender;
@end

@implementation YouModQueueManager {
    NSMutableArray <NSDictionary *> *_items;
    NSMutableSet <NSString *> *_metadataRequests;
}

+ (instancetype)shared {
    static YouModQueueManager *manager;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [YouModQueueManager new];
    });
    return manager;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _items = [NSMutableArray array];
        _metadataRequests = [NSMutableSet set];
        NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:YouModQueueItemsKey];
        for (id entry in stored) {
            if (![entry isKindOfClass:NSDictionary.class]) continue;
            if (!YouModQueueIsValidVideoID(entry[YouModQueueItemID])) continue;
            [_items addObject:entry];
        }
    }
    return self;
}

- (void)saveAndNotify {
    [[NSUserDefaults standardUserDefaults] setObject:_items.copy forKey:YouModQueueItemsKey];
    [[NSNotificationCenter defaultCenter] postNotificationName:YouModQueueDidChangeNotification object:self];
}

- (NSArray <NSDictionary *> *)items {
    return _items.copy;
}

- (NSUInteger)count {
    return _items.count;
}

- (NSUInteger)indexOfVideoID:(NSString *)videoID {
    if (videoID.length == 0) return NSNotFound;
    return [_items indexOfObjectPassingTest:^BOOL(NSDictionary *item, __unused NSUInteger idx, __unused BOOL *stop) {
        return [item[YouModQueueItemID] isEqualToString:videoID];
    }];
}

// The first queued video that is not the one already playing.
- (NSString *)nextVideoIDExcluding:(NSString *)videoID {
    for (NSDictionary *item in _items) {
        NSString *itemID = item[YouModQueueItemID];
        if (videoID.length && [itemID isEqualToString:videoID]) continue;
        return itemID;
    }
    return nil;
}

- (BOOL)containsVideoID:(NSString *)videoID {
    return [self indexOfVideoID:videoID] != NSNotFound;
}

- (BOOL)addVideoID:(NSString *)videoID title:(NSString *)title author:(NSString *)author atFront:(BOOL)atFront {
    if (!YouModQueueIsValidVideoID(videoID)) return NO;
    NSUInteger existing = [self indexOfVideoID:videoID];
    NSMutableDictionary *item = [NSMutableDictionary dictionary];
    if (existing != NSNotFound) {
        if (!atFront) return NO;
        [item addEntriesFromDictionary:_items[existing]];
        [_items removeObjectAtIndex:existing];
    }
    item[YouModQueueItemID] = videoID;
    if (title.length) item[YouModQueueItemTitle] = title;
    if (author.length) item[YouModQueueItemAuthor] = author;
    if (atFront)
        [_items insertObject:item.copy atIndex:0];
    else
        [_items addObject:item.copy];
    [self saveAndNotify];
    if ([item[YouModQueueItemTitle] length] == 0) [self fetchMetadataForVideoID:videoID];
    return YES;
}

- (void)removeItemAtIndex:(NSUInteger)index {
    if (index >= _items.count) return;
    [_items removeObjectAtIndex:index];
    [self saveAndNotify];
}

- (void)removeVideoID:(NSString *)videoID {
    NSUInteger index = [self indexOfVideoID:videoID];
    if (index != NSNotFound) [self removeItemAtIndex:index];
}

- (void)moveItemFromIndex:(NSUInteger)fromIndex toIndex:(NSUInteger)toIndex {
    if (fromIndex >= _items.count || toIndex >= _items.count || fromIndex == toIndex) return;
    NSDictionary *item = _items[fromIndex];
    [_items removeObjectAtIndex:fromIndex];
    [_items insertObject:item atIndex:toIndex];
    [self saveAndNotify];
}

- (void)clear {
    if (_items.count == 0) return;
    [_items removeAllObjects];
    [self saveAndNotify];
}

// Videos added from a menu or a link only come with an ID, so look up the title afterwards.
- (void)fetchMetadataForVideoID:(NSString *)videoID {
    if ([_metadataRequests containsObject:videoID]) return;
    [_metadataRequests addObject:videoID];
    NSString *urlString = [NSString stringWithFormat:@"https://www.youtube.com/oembed?format=json&url=https%%3A%%2F%%2Fwww.youtube.com%%2Fwatch%%3Fv%%3D%@", videoID];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return;
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:NSDictionary.class]) return;
        NSString *title = [json[@"title"] isKindOfClass:NSString.class] ? json[@"title"] : nil;
        NSString *author = [json[@"author_name"] isKindOfClass:NSString.class] ? json[@"author_name"] : nil;
        if (title.length == 0) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSUInteger index = [self indexOfVideoID:videoID];
            if (index == NSNotFound) return;
            NSMutableDictionary *item = [self->_items[index] mutableCopy];
            item[YouModQueueItemTitle] = title;
            if (author.length) item[YouModQueueItemAuthor] = author;
            self->_items[index] = item.copy;
            [self saveAndNotify];
        });
    }] resume];
}

- (void)fetchMissingMetadata {
    for (NSDictionary *item in _items.copy) {
        if ([item[YouModQueueItemTitle] length] == 0) [self fetchMetadataForVideoID:item[YouModQueueItemID]];
    }
}

- (void)addCurrentVideoAtFront:(BOOL)atFront {
    YTPlayerViewController *player = YouModQueueMainPlayer;
    NSString *videoID = YouModQueueVideoIDForPlayer(player);
    if (!videoID) {
        YouModQueueToast(@"Open a video first.");
        return;
    }
    YTIVideoDetails *details = YouModQueueVideoDetailsForPlayer(player);
    NSString *title = [details respondsToSelector:@selector(title)] ? [details title] : nil;
    NSString *author = [details respondsToSelector:@selector(author)] ? [details author] : nil;
    BOOL added = [self addVideoID:videoID title:title author:author atFront:atFront];
    YouModQueueToast(added ? (atFront ? @"Playing next" : @"Added to queue") : @"Already in queue");
}

- (void)handleSaveLongPress:(UILongPressGestureRecognizer *)sender {
    if (sender.state != UIGestureRecognizerStateBegan) return;
    UIViewController *presenter = YouModQueueTopViewController(nil);
    if (!presenter) return;

    NSString *viewTitle = [NSString stringWithFormat:@"View queue (%lu)", (unsigned long)self.count];
    NSArray <NSArray *> *rows = @[
        @[@"Add to queue", @"text.badge.plus", ^{ [self addCurrentVideoAtFront:NO]; }],
        @[@"Play next", @"text.insert", ^{ [self addCurrentVideoAtFront:YES]; }],
        @[viewTitle, @"list.bullet", ^{ YouModQueuePresent(nil); }],
    ];

    Class sheetClass = %c(YTDefaultSheetController);
    Class actionClass = %c(YTActionSheetAction);
    if ([sheetClass respondsToSelector:@selector(sheetControllerWithParentResponder:)] && [actionClass respondsToSelector:@selector(actionWithTitle:iconImage:style:handler:)]) {
        YTDefaultSheetController *sheet = [sheetClass sheetControllerWithParentResponder:presenter];
        for (NSArray *row in rows) {
            void (^handler)(void) = row[2];
            UIImage *icon = [[UIImage systemImageNamed:row[1]] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            YTActionSheetAction *action = [actionClass actionWithTitle:row[0] iconImage:icon style:0 handler:^(__unused YTActionSheetAction *sheetAction) {
                handler();
            }];
            if (action) [sheet addAction:action];
        }
        if (sender.view && [sheet respondsToSelector:@selector(presentFromView:animated:completion:)])
            [sheet presentFromView:sender.view animated:YES completion:nil];
        else
            [sheet presentFromViewController:presenter animated:YES completion:nil];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Queue" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSArray *row in rows) {
        void (^handler)(void) = row[2];
        [alert addAction:[UIAlertAction actionWithTitle:row[0] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *alertAction) {
            handler();
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.sourceView = sender.view ?: presenter.view;
    [presenter presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Navigation

static id YouModQueueResponder(void) {
    YTPlayerViewController *player = YouModQueueMainPlayer;
    if (player && [player respondsToSelector:@selector(parentResponder)]) return player;
    return YouModQueueTopViewController(nil);
}

// Opens the video the same way a tapped cell does. Works without bringing the app to the foreground.
static BOOL YouModQueueSendWatchCommand(NSString *videoID) {
    Class commandClass = %c(YTICommand);
    Class eventClass = %c(YTCommandResponderEvent);
    if (!eventClass || ![commandClass respondsToSelector:@selector(watchNavigationEndpointWithVideoID:)]) return NO;
    @try {
        YTICommand *command = [commandClass watchNavigationEndpointWithVideoID:videoID];
        id responder = YouModQueueResponder();
        if (!command || !responder) return NO;
        YTCommandResponderEvent *event = nil;
        if ([eventClass respondsToSelector:@selector(eventWithCommand:fromView:entry:sendClick:firstResponder:)])
            event = [eventClass eventWithCommand:command fromView:nil entry:nil sendClick:NO firstResponder:responder];
        else if ([eventClass respondsToSelector:@selector(eventWithCommand:entry:sendClick:firstResponder:)])
            event = [eventClass eventWithCommand:command entry:nil sendClick:NO firstResponder:responder];
        if (!event) return NO;
        [event send];
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

// Last resort: hand the app its own deep link.
static void YouModQueueOpenDeepLink(NSString *videoID) {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"youtube://www.youtube.com/watch?v=%@", videoID]];
    if (!url) return;
    UIApplication *application = UIApplication.sharedApplication;
    id <UIApplicationDelegate> delegate = application.delegate;
    @try {
        if ([delegate respondsToSelector:@selector(application:openURL:options:)] && [delegate application:application openURL:url options:@{}]) return;
    } @catch (__unused NSException *exception) {
    }
    [application openURL:url options:@{} completionHandler:nil];
}

void YouModQueuePlayVideoID(NSString *videoID) {
    if (!YouModQueueIsValidVideoID(videoID)) return;
    YouModQueuePendingVideoID = videoID;
    if (!YouModQueueSendWatchCommand(videoID)) {
        YouModQueueOpenDeepLink(videoID);
        return;
    }
    // If the command was swallowed, the video never shows up in the player. Fall back to the deep link.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![YouModQueuePendingVideoID isEqualToString:videoID]) return;
        if ([YouModQueueVideoIDForPlayer(YouModQueueMainPlayer) isEqualToString:videoID]) return;
        YouModQueueOpenDeepLink(videoID);
    });
}

#pragma mark - Playback tracking

// Called whenever the watch player reports in. Removes a queued video once it actually starts loading,
// so an item is only ever dropped from the queue when it really made it to the player.
static void YouModQueueNotePlayer(YTPlayerViewController *player) {
    if (!YouModQueueIsMainPlayer(player)) return;
    NSString *videoID = YouModQueueVideoIDForPlayer(player);
    if (!videoID) return;
    YouModQueueMainPlayer = player;
    if ([videoID isEqualToString:YouModQueueTrackedVideoID]) return;

    YouModQueueTrackedVideoID = videoID;
    YouModQueueSawEarlierPosition = NO;
    YouModQueueFiredForCurrentVideo = NO;
    YouModQueueLastTotalTime = 0;
    YouModQueueTotalGrowthCount = 0;

    YouModQueueManager *manager = [YouModQueueManager shared];
    BOOL wasPending = [videoID isEqualToString:YouModQueuePendingVideoID];
    if (wasPending) YouModQueuePendingVideoID = nil;
    if (wasPending || [videoID isEqualToString:[manager nextVideoIDExcluding:nil]]) [manager removeVideoID:videoID];
}

static void YouModQueueTick(YTPlayerViewController *player) {
    YouModQueueNotePlayer(player);
    if (player != YouModQueueMainPlayer || YouModQueueFiredForCurrentVideo) return;
    if (player.isPlayingAd) return;

    YouModQueueManager *manager = [YouModQueueManager shared];
    if (manager.count == 0) return;

    CGFloat total = [player currentVideoTotalMediaTime];
    CGFloat current = [player currentVideoMediaTime];
    if (total < 1.0) return;

    // A total that keeps growing means a live stream, which has no end to wait for.
    if (YouModQueueLastTotalTime > 0 && total > YouModQueueLastTotalTime + 0.5) YouModQueueTotalGrowthCount++;
    YouModQueueLastTotalTime = total;
    if (YouModQueueTotalGrowthCount >= 3) return;

    if (current < total - MIN(3.0, total / 2.0)) {
        YouModQueueSawEarlierPosition = YES;
        return;
    }
    if (!YouModQueueSawEarlierPosition || current < total - YouModQueueEndThreshold) return;

    YTIVideoDetails *details = YouModQueueVideoDetailsForPlayer(player);
    if ([details respondsToSelector:@selector(isLive)] && [details isLive]) return;

    NSString *next = [manager nextVideoIDExcluding:YouModQueueTrackedVideoID];
    if (!next) return;
    YouModQueueFiredForCurrentVideo = YES;
    YouModQueuePlayVideoID(next);
}

#pragma mark - Queue screen

static NSCache <NSString *, UIImage *> *YouModQueueThumbnailCache(void) {
    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [NSCache new];
        cache.countLimit = 100;
    });
    return cache;
}

@interface YouModQueueCell : UITableViewCell
@property (nonatomic, copy) NSString *videoID;
@property (nonatomic, strong) UIImageView *thumbnailView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *authorLabel;
- (void)configureWithItem:(NSDictionary *)item;
@end

@implementation YouModQueueCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        _thumbnailView = [UIImageView new];
        _thumbnailView.translatesAutoresizingMaskIntoConstraints = NO;
        _thumbnailView.contentMode = UIViewContentModeScaleAspectFill;
        _thumbnailView.clipsToBounds = YES;
        _thumbnailView.layer.cornerRadius = 6.0;
        _thumbnailView.backgroundColor = [UIColor secondarySystemFillColor];
        [self.contentView addSubview:_thumbnailView];

        _titleLabel = [UILabel new];
        _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        _titleLabel.adjustsFontForContentSizeCategory = YES;
        _titleLabel.textColor = [UIColor labelColor];
        _titleLabel.numberOfLines = 2;

        _authorLabel = [UILabel new];
        _authorLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
        _authorLabel.adjustsFontForContentSizeCategory = YES;
        _authorLabel.textColor = [UIColor secondaryLabelColor];

        UIStackView *labels = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _authorLabel]];
        labels.translatesAutoresizingMaskIntoConstraints = NO;
        labels.axis = UILayoutConstraintAxisVertical;
        labels.spacing = 2.0;
        [self.contentView addSubview:labels];

        UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
        NSLayoutConstraint *thumbnailBottom = [_thumbnailView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-8.0];
        thumbnailBottom.priority = UILayoutPriorityDefaultHigh;
        [NSLayoutConstraint activateConstraints:@[
            [_thumbnailView.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [_thumbnailView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:8.0],
            thumbnailBottom,
            [_thumbnailView.widthAnchor constraintEqualToConstant:112.0],
            [_thumbnailView.heightAnchor constraintEqualToConstant:63.0],
            [labels.leadingAnchor constraintEqualToAnchor:_thumbnailView.trailingAnchor constant:12.0],
            [labels.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [labels.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
            [labels.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:8.0],
            [labels.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-8.0],
        ]];
    }
    return self;
}

- (void)configureWithItem:(NSDictionary *)item {
    NSString *videoID = item[YouModQueueItemID];
    NSString *title = item[YouModQueueItemTitle];
    self.titleLabel.text = title.length ? title : [NSString stringWithFormat:@"Video %@", videoID];
    self.authorLabel.text = item[YouModQueueItemAuthor];
    self.authorLabel.hidden = [item[YouModQueueItemAuthor] length] == 0;
    if ([self.videoID isEqualToString:videoID] && self.thumbnailView.image) return;

    self.videoID = videoID;
    UIImage *cached = [YouModQueueThumbnailCache() objectForKey:videoID];
    self.thumbnailView.image = cached;
    if (cached) return;

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/mqdefault.jpg", videoID]];
    if (!url) return;
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, __unused NSURLResponse *response, __unused NSError *error) {
        UIImage *image = data ? [UIImage imageWithData:data] : nil;
        if (!image) return;
        [YouModQueueThumbnailCache() setObject:image forKey:videoID];
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([weakSelf.videoID isEqualToString:videoID]) weakSelf.thumbnailView.image = image;
        });
    }] resume];
}

@end

@interface YouModQueueViewController : UITableViewController
@end

@implementation YouModQueueViewController {
    NSArray <NSDictionary *> *_items;
    BOOL _ignoreNextChange;
}

- (instancetype)init {
    return [super initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Queue";
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 79.0;
    self.tableView.tableFooterView = [UIView new];
    [self.tableView registerClass:YouModQueueCell.class forCellReuseIdentifier:@"YouModQueueCell"];

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    UIBarButtonItem *addItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(showAddMenu:)];
    UIBarButtonItem *clearItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash target:self action:@selector(confirmClear:)];
    self.navigationItem.rightBarButtonItems = @[self.editButtonItem, addItem, clearItem];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(queueDidChange) name:YouModQueueDidChangeNotification object:nil];
    [[YouModQueueManager shared] fetchMissingMetadata];
    [self reloadItems];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)reloadItems {
    _items = [[YouModQueueManager shared] items];
    [self.tableView reloadData];
    [self updateEmptyState];
}

- (void)updateEmptyState {
    if (_items.count > 0) {
        self.tableView.backgroundView = nil;
        return;
    }
    UILabel *label = [UILabel new];
    label.text = @"Your queue is empty.\n\nLong-press the Save button under a video, use a video's menu, or tap + to add videos.";
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.textColor = [UIColor secondaryLabelColor];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    UIView *container = [UIView new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [label.leadingAnchor constraintEqualToAnchor:container.layoutMarginsGuide.leadingAnchor constant:16.0],
        [label.trailingAnchor constraintEqualToAnchor:container.layoutMarginsGuide.trailingAnchor constant:-16.0],
    ]];
    self.tableView.backgroundView = container;
}

- (void)queueDidChange {
    if (_ignoreNextChange) {
        _ignoreNextChange = NO;
        _items = [[YouModQueueManager shared] items];
        [self updateEmptyState];
        return;
    }
    [self reloadItems];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)showAddMenu:(UIBarButtonItem *)sender {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Add to queue" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    if (YouModQueueVideoIDForPlayer(YouModQueueMainPlayer)) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Current video" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [[YouModQueueManager shared] addCurrentVideoAtFront:NO];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Copied link" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *videoID = YouModQueueVideoIDFromText(UIPasteboard.generalPasteboard.string);
        if (!videoID) {
            [self showMessage:@"No YouTube video link was found on the clipboard. Use Share > Copy link on a video first."];
            return;
        }
        if (![[YouModQueueManager shared] addVideoID:videoID title:nil author:nil atFront:NO])
            [self showMessage:@"That video is already in the queue."];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)confirmClear:(UIBarButtonItem *)sender {
    if (_items.count == 0) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear queue" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        [[YouModQueueManager shared] clear];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    alert.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    YouModQueueCell *cell = [tableView dequeueReusableCellWithIdentifier:@"YouModQueueCell" forIndexPath:indexPath];
    [cell configureWithItem:_items[indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *videoID = _items[indexPath.row][YouModQueueItemID];
    [self dismissViewControllerAnimated:YES completion:^{
        YouModQueuePlayVideoID(videoID);
    }];
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)sourceIndexPath toIndexPath:(NSIndexPath *)destinationIndexPath {
    if (sourceIndexPath.row == destinationIndexPath.row) return;
    _ignoreNextChange = YES;
    [[YouModQueueManager shared] moveItemFromIndex:sourceIndexPath.row toIndex:destinationIndexPath.row];
}

- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)editingStyle forRowAtIndexPath:(NSIndexPath *)indexPath {
    if (editingStyle != UITableViewCellEditingStyleDelete) return;
    _ignoreNextChange = YES;
    [[YouModQueueManager shared] removeItemAtIndex:indexPath.row];
    [tableView deleteRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
}

@end

void YouModQueuePresent(UIViewController *presenter) {
    presenter = YouModQueueTopViewController(presenter);
    if (!presenter || [presenter isKindOfClass:YouModQueueViewController.class]) return;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:[YouModQueueViewController new]];
    [presenter presentViewController:navigation animated:YES completion:nil];
}

NSUInteger YouModQueueCount(void) {
    return [[YouModQueueManager shared] count];
}

#pragma mark - Entry points in YouTube's UI

// Long-pressing the Save button under the player opens the queue menu.
void YouModConfigureQueueButton(_ASDisplayView *view) {
    if (!YouModQueueActive) return;
    if (![view.accessibilityIdentifier isEqualToString:@"id.video.add_to.button"]) return;
    static char configuredKey;
    if (objc_getAssociatedObject(view, &configuredKey)) return;

    view.userInteractionEnabled = YES;
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:[YouModQueueManager shared] action:@selector(handleSaveLongPress:)];
    [view addGestureRecognizer:longPress];
    objc_setAssociatedObject(view, &configuredKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// A video's menu does not expose its ID directly, but its entries (save to Watch later, etc.) carry it.
// Pick the ID that the menu's own commands refer to most often.
static NSString *YouModQueueVideoIDFromMenuRenderers(NSArray *renderers) {
    if (![renderers isKindOfClass:NSArray.class] || renderers.count == 0) return nil;
    static NSRegularExpression *regex;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        regex = [NSRegularExpression regularExpressionWithPattern:@"video_?id:\\s*\"([A-Za-z0-9_-]{11})\"" options:NSRegularExpressionCaseInsensitive error:nil];
    });
    NSCountedSet <NSString *> *counts = [NSCountedSet set];
    for (id renderer in renderers) {
        NSString *text = [renderer description];
        if (text.length == 0 || text.length > 200000) continue;
        [regex enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length) usingBlock:^(NSTextCheckingResult *match, __unused NSMatchingFlags flags, __unused BOOL *stop) {
            if (match.numberOfRanges > 1) [counts addObject:[text substringWithRange:[match rangeAtIndex:1]]];
        }];
    }
    NSString *best = nil;
    for (NSString *candidate in counts) {
        if (!best || [counts countForObject:candidate] > [counts countForObject:best]) best = candidate;
    }
    return best;
}

%group Queue

%hook YTPlayerViewController

- (void)loadWithPlayerTransition:(id)arg1 playbackConfig:(id)arg2 {
    %orig;
    // The video ID is not available yet at this point, so check back shortly after.
    __weak typeof(self) weakSelf = self;
    for (NSNumber *delay in @[@1.0, @2.5]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (weakSelf) YouModQueueNotePlayer(weakSelf);
        });
    }
}

- (void)singleVideo:(id)video currentVideoTimeDidChange:(YTSingleVideoTime *)time {
    %orig;
    YouModQueueTick(self);
}

- (void)potentiallyMutatedSingleVideo:(id)video currentVideoTimeDidChange:(YTSingleVideoTime *)time {
    %orig;
    YouModQueueTick(self);
}

%end

// Makes YouTube's own "next" (autoplay, the player's next button, lock screen controls) go to the queue.
// The item is not removed here because this is also called just to look ahead; it is removed once it loads.
%hook YTAutoplayAutonavController

- (id)nextEndpointForAutoplay {
    id original = %orig;
    Class commandClass = %c(YTICommand);
    if (original && ![original isKindOfClass:commandClass]) return original;
    NSString *next = [[YouModQueueManager shared] nextVideoIDExcluding:YouModQueueTrackedVideoID];
    if (!next || ![commandClass respondsToSelector:@selector(watchNavigationEndpointWithVideoID:)]) return original;
    return [commandClass watchNavigationEndpointWithVideoID:next] ?: original;
}

%end

// Adds "Add to queue" to a video's three-dot menu.
%hook YTMenuController

- (NSMutableArray *)actionsForRenderers:(NSMutableArray *)renderers fromView:(UIView *)fromView entry:(id)entry shouldLogItems:(BOOL)shouldLogItems firstResponder:(id)firstResponder {
    NSMutableArray *actions = %orig;
    @try {
        NSString *videoID = YouModQueueVideoIDFromMenuRenderers(renderers);
        Class actionClass = %c(YTActionSheetAction);
        if (videoID && [actions isKindOfClass:NSArray.class] && [actionClass respondsToSelector:@selector(actionWithTitle:iconImage:style:handler:)]) {
            UIImage *icon = [[UIImage systemImageNamed:@"text.badge.plus"] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            YTActionSheetAction *action = [actionClass actionWithTitle:@"Add to YouMod queue" iconImage:icon style:0 handler:^(__unused YTActionSheetAction *sheetAction) {
                BOOL added = [[YouModQueueManager shared] addVideoID:videoID title:nil author:nil atFront:NO];
                YouModQueueToast(added ? @"Added to queue" : @"Already in queue");
            }];
            if (action) {
                if (![actions isKindOfClass:NSMutableArray.class]) actions = [actions mutableCopy];
                [actions addObject:action];
            }
        }
    } @catch (__unused NSException *exception) {
    }
    return actions;
}

%end

%end

%ctor {
    if (IS_ENABLED(CustomQueue)) {
        YouModQueueActive = YES;
        %init(Queue);
    }
}
