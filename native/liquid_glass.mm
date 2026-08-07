#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <napi.h>
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <QuartzCore/QuartzCore.h>

@interface LeetCodeGlassEffectView : NSGlassEffectView
@end

@implementation LeetCodeGlassEffectView

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (!self) return nil;
  self.wantsLayer = YES;
  self.layer.masksToBounds = YES;
  self.layer.cornerCurve = kCACornerCurveContinuous;
  return self;
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
  [super setCornerRadius:cornerRadius];
  self.layer.cornerRadius = cornerRadius;
}

- (NSView *)hitTest:(NSPoint)point {
  return nil;
}
@end

@interface LeetCodeCenteredTextFieldCell : NSTextFieldCell
@end

@implementation LeetCodeCenteredTextFieldCell

- (NSRect)drawingRectForBounds:(NSRect)rect {
  NSRect drawingRect = [super drawingRectForBounds:rect];
  const CGFloat textHeight = ceil(self.font.ascender - self.font.descender);
  if (textHeight < NSHeight(drawingRect)) {
    drawingRect.origin.y += floor((NSHeight(drawingRect) - textHeight) * 0.5);
    drawingRect.size.height = textHeight;
  }
  return drawingRect;
}

@end

void CallNavigationCallback(
  Napi::Env env,
  Napi::Function callback,
  std::nullptr_t *,
  std::string *action
);

using NavigationThreadSafeFunction = Napi::TypedThreadSafeFunction<
  std::nullptr_t,
  std::string,
  CallNavigationCallback
>;

static std::unique_ptr<NavigationThreadSafeFunction> gNavigationCallback;

static void DispatchNavigationCommand(const char *action) {
  if (!gNavigationCallback || !action) return;
  auto *payload = new std::string(action);
  napi_status status = gNavigationCallback->NonBlockingCall(payload);
  if (status != napi_ok) delete payload;
}

void CallNavigationCallback(
  Napi::Env env,
  Napi::Function callback,
  std::nullptr_t *,
  std::string *action
) {
  std::unique_ptr<std::string> ownedAction(action);
  if (env == nullptr || callback.IsEmpty()) return;
  callback.Call({Napi::String::New(env, *ownedAction)});
}

@interface LeetCodeWindowDelegateProxy : NSProxy <NSWindowDelegate> {
  __weak id<NSWindowDelegate> _originalDelegate;
}
- (instancetype)initWithDelegate:(id<NSWindowDelegate>)delegate;
@property(nonatomic, weak, readonly) id<NSWindowDelegate> originalDelegate;
@end

@implementation LeetCodeWindowDelegateProxy

- (instancetype)initWithDelegate:(id<NSWindowDelegate>)delegate {
  _originalDelegate = delegate;
  return self;
}

- (id<NSWindowDelegate>)originalDelegate {
  return _originalDelegate;
}

- (BOOL)respondsToSelector:(SEL)selector {
  if (selector == @selector(window:willUseFullScreenPresentationOptions:)) return YES;
  return [_originalDelegate respondsToSelector:selector];
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
  return [(NSObject *)_originalDelegate methodSignatureForSelector:selector];
}

- (void)forwardInvocation:(NSInvocation *)invocation {
  if ([_originalDelegate respondsToSelector:invocation.selector]) {
    [invocation invokeWithTarget:_originalDelegate];
    return;
  }
  [NSException raise:NSInvalidArgumentException
              format:@"Unrecognized NSWindow delegate selector: %@",
                     NSStringFromSelector(invocation.selector)];
}

- (NSApplicationPresentationOptions)window:(NSWindow *)window
          willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)proposedOptions {
  NSApplicationPresentationOptions options = proposedOptions;
  if ([_originalDelegate respondsToSelector:_cmd]) {
    options = [_originalDelegate window:window willUseFullScreenPresentationOptions:proposedOptions];
  }
  if (options & NSApplicationPresentationFullScreen) {
    options |= NSApplicationPresentationAutoHideToolbar;
  }
  return options;
}

@end

@interface LeetCodeLiquidSegmentedControl : NSControl
@property(nonatomic) NSInteger selectedSegment;
@property(nonatomic) CGFloat preferredWidth;
- (instancetype)initWithLabels:(NSArray<NSString *> *)labels;
@end

@implementation LeetCodeLiquidSegmentedControl {
  LeetCodeGlassEffectView *_selectionGlass;
  NSView *_glassContent;
  NSArray<NSTextField *> *_labels;
  BOOL _draggingSelection;
  CGFloat _dragCenterX;
}

- (instancetype)initWithLabels:(NSArray<NSString *> *)labels {
  self = [super initWithFrame:NSMakeRect(0, 0, 360, 30)];
  if (!self) return nil;

  self.wantsLayer = YES;
  self.layer.masksToBounds = NO;
  self.refusesFirstResponder = YES;
  self.focusRingType = NSFocusRingTypeNone;
  self.preferredWidth = 360.0;
  [self setContentHuggingPriority:NSLayoutPriorityRequired
                   forOrientation:NSLayoutConstraintOrientationHorizontal];
  [self setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                  forOrientation:NSLayoutConstraintOrientationHorizontal];
  self.toolTip = @"拖动或点击切换学习区域";
  self.accessibilityLabel = @"学习区域";
  self.accessibilityRole = NSAccessibilityTabGroupRole;

  _glassContent = [[NSView alloc] initWithFrame:self.bounds];
  _glassContent.wantsLayer = YES;
  _glassContent.layer.masksToBounds = NO;
  [self addSubview:_glassContent];

  _selectionGlass = [[LeetCodeGlassEffectView alloc] initWithFrame:NSZeroRect];
  _selectionGlass.style = NSGlassEffectViewStyleRegular;
  _selectionGlass.tintColor = [NSColor colorWithSRGBRed:0.18 green:0.45 blue:0.68 alpha:0.16];
  if (@available(macOS 27.0, *)) _selectionGlass.effectIsInteractive = YES;
  [_glassContent addSubview:_selectionGlass];

  NSMutableArray<NSTextField *> *labelViews = [NSMutableArray arrayWithCapacity:labels.count];
  for (NSString *text in labels) {
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSZeroRect];
    label.cell = [[LeetCodeCenteredTextFieldCell alloc] initTextCell:text];
    label.bezeled = NO;
    label.bordered = NO;
    label.drawsBackground = NO;
    label.editable = NO;
    label.selectable = NO;
    label.alignment = NSTextAlignmentCenter;
    label.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightMedium];
    label.textColor = NSColor.secondaryLabelColor;
    label.lineBreakMode = NSLineBreakByClipping;
    label.maximumNumberOfLines = 1;
    [_glassContent addSubview:label];
    [labelViews addObject:label];
  }
  _labels = labelViews;
  _selectedSegment = -1;
  return self;
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(self.preferredWidth, 30);
}

- (void)setPreferredWidth:(CGFloat)preferredWidth {
  const CGFloat normalized = round(MAX(1.0, preferredWidth));
  if (fabs(_preferredWidth - normalized) < 0.5) return;
  _preferredWidth = normalized;
  [self invalidateIntrinsicContentSize];
}

- (CGFloat)contentInset {
  return MIN(5.0, MAX(3.0, round(NSHeight(self.bounds) * 0.105)));
}

- (CGFloat)selectionCornerRadius {
  return MAX(0.0, NSHeight(self.bounds) * 0.5 - [self contentInset]);
}

- (NSRect)selectionFrameForCenterX:(CGFloat)centerX {
  const CGFloat outerInset = [self contentInset];
  const CGFloat slotWidth = (NSWidth(self.bounds) - outerInset * 2.0) / MAX((NSUInteger)1, _labels.count);
  const CGFloat width = MAX(0.0, slotWidth);
  const CGFloat minCenter = outerInset + slotWidth * 0.5;
  const CGFloat maxCenter = NSWidth(self.bounds) - outerInset - slotWidth * 0.5;
  const CGFloat clampedCenter = MIN(maxCenter, MAX(minCenter, centerX));
  return NSMakeRect(clampedCenter - width * 0.5, outerInset, width, NSHeight(self.bounds) - outerInset * 2.0);
}

- (CGFloat)centerXForSegment:(NSInteger)segment {
  if (segment < 0 || segment >= (NSInteger)_labels.count) return -1000.0;
  const CGFloat outerInset = [self contentInset];
  const CGFloat slotWidth = (NSWidth(self.bounds) - outerInset * 2.0) / _labels.count;
  return outerInset + slotWidth * (segment + 0.5);
}

- (NSInteger)segmentForX:(CGFloat)x {
  const CGFloat outerInset = [self contentInset];
  const CGFloat slotWidth = (NSWidth(self.bounds) - outerInset * 2.0) / MAX((NSUInteger)1, _labels.count);
  const NSInteger segment = (NSInteger)floor((x - outerInset) / slotWidth);
  return MIN((NSInteger)_labels.count - 1, MAX((NSInteger)0, segment));
}

- (void)updateLabelAppearanceForSegment:(NSInteger)segment {
  [_labels enumerateObjectsUsingBlock:^(NSTextField *label, NSUInteger index, BOOL *stop) {
    const BOOL active = (NSInteger)index == segment;
    label.textColor = active ? NSColor.labelColor : NSColor.secondaryLabelColor;
    label.font = [NSFont systemFontOfSize:12.5
                                  weight:active ? NSFontWeightSemibold : NSFontWeightMedium];
  }];
}

- (void)layout {
  [super layout];
  _glassContent.frame = self.bounds;

  const CGFloat outerInset = [self contentInset];
  const CGFloat slotWidth = (NSWidth(self.bounds) - outerInset * 2.0)
    / MAX((NSUInteger)1, _labels.count);
  [_labels enumerateObjectsUsingBlock:^(NSTextField *label, NSUInteger index, BOOL *stop) {
    label.frame = NSMakeRect(
      outerInset + slotWidth * index,
      0.0,
      slotWidth,
      NSHeight(self.bounds)
    );
  }];

  const CGFloat targetCenter = _draggingSelection
    ? _dragCenterX
    : [self centerXForSegment:self.selectedSegment];
  _selectionGlass.frame = [self selectionFrameForCenterX:targetCenter];
  _selectionGlass.cornerRadius = [self selectionCornerRadius];
  _selectionGlass.hidden = self.selectedSegment < 0 && !_draggingSelection;
}

- (void)setSelectedSegment:(NSInteger)selectedSegment {
  const NSInteger normalized = selectedSegment >= 0 && selectedSegment < (NSInteger)_labels.count
    ? selectedSegment
    : -1;
  const BOOL changed = normalized != _selectedSegment;
  const BOOL wasDragging = _draggingSelection;
  _selectedSegment = normalized;
  _draggingSelection = NO;
  [self updateLabelAppearanceForSegment:normalized];
  _selectionGlass.hidden = normalized < 0;
  if (!changed && !wasDragging) return;
  if (normalized < 0 || NSWidth(self.bounds) <= 0) {
    [self setNeedsLayout:YES];
    return;
  }
  const NSRect target = [self selectionFrameForCenterX:[self centerXForSegment:normalized]];
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
    context.duration = 0.28;
    context.allowsImplicitAnimation = YES;
    context.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.22 :0.72 :0.18 :1.0];
    _selectionGlass.animator.frame = target;
    _selectionGlass.animator.cornerRadius = [self selectionCornerRadius];
  }];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)mouseDown:(NSEvent *)event {
  if (!self.isEnabled || _labels.count == 0) return;
  const NSPoint initialPoint = [self convertPoint:event.locationInWindow fromView:nil];
  NSPoint point = initialPoint;

  while (YES) {
    NSEvent *next = [self.window nextEventMatchingMask:(NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp)];
    point = [self convertPoint:next.locationInWindow fromView:nil];
    if (next.type == NSEventTypeLeftMouseDragged) {
      if (!_draggingSelection && hypot(point.x - initialPoint.x, point.y - initialPoint.y) < 3.0) continue;
      if (!_draggingSelection) {
        _draggingSelection = YES;
        _selectionGlass.hidden = NO;
        _selectionGlass.tintColor = [NSColor colorWithSRGBRed:0.16 green:0.48 blue:0.76 alpha:0.22];
      }
      _dragCenterX = point.x;
      _selectionGlass.frame = [self selectionFrameForCenterX:_dragCenterX];
      _selectionGlass.cornerRadius = [self selectionCornerRadius];
      [self updateLabelAppearanceForSegment:[self segmentForX:point.x]];
      continue;
    }

    const NSInteger target = [self segmentForX:point.x];
    if (_draggingSelection) {
      _selectionGlass.tintColor = [NSColor colorWithSRGBRed:0.18 green:0.45 blue:0.68 alpha:0.16];
    }
    self.selectedSegment = target;
    [self sendAction:self.action to:self.target];
    break;
  }
}

@end

@interface LeetCodeNavigationToolbarController : NSObject <NSToolbarDelegate>
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic, strong) NSToolbar *toolbar;
@property(nonatomic, strong) LeetCodeLiquidSegmentedControl *navigationControl;
@property(nonatomic, strong) LeetCodeWindowDelegateProxy *windowDelegateProxy;
@property(nonatomic, strong) id willEnterFullscreenObserver;
@property(nonatomic, strong) id didEnterFullscreenObserver;
@property(nonatomic, strong) id windowResizeObserver;
@property(nonatomic, strong) id windowScreenObserver;
@property(nonatomic, strong) id windowBackingObserver;
@property(nonatomic, strong) id didExitFullscreenObserver;
@property(nonatomic) BOOL navigationActive;
- (instancetype)initWithWindow:(NSWindow *)window;
- (void)setSelectedSegment:(NSInteger)segment;
- (void)uninstall;
@end

@implementation LeetCodeNavigationToolbarController

static NSToolbarItemIdentifier const LeetCodeNavigationItemIdentifier = @"LeetCode.LearningNavigation";

- (instancetype)initWithWindow:(NSWindow *)window {
  self = [super init];
  if (!self) return nil;

  _window = window;
  _toolbar = [[NSToolbar alloc] initWithIdentifier:@"LeetCode.FullscreenNavigation"];
  _toolbar.delegate = self;
  _toolbar.allowsUserCustomization = NO;
  _toolbar.autosavesConfiguration = NO;
  _toolbar.displayMode = NSToolbarDisplayModeIconOnly;
  if (@available(macOS 15.0, *)) _toolbar.allowsDisplayModeCustomization = NO;
  _toolbar.centeredItemIdentifiers = [NSSet setWithObject:LeetCodeNavigationItemIdentifier];
  _toolbar.visible = NO;

  _navigationControl = [[LeetCodeLiquidSegmentedControl alloc]
    initWithLabels:@[@"今日", @"力扣", @"知识库", @"洞察"]];
  _navigationControl.target = self;
  _navigationControl.action = @selector(selectLearningRegion:);

  window.toolbarStyle = NSWindowToolbarStyleUnifiedCompact;
  window.titleVisibility = NSWindowTitleHidden;
  window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
  window.toolbar = _toolbar;

  _navigationActive = NO;
  _toolbar.visible = NO;
  _windowDelegateProxy = [[LeetCodeWindowDelegateProxy alloc] initWithDelegate:window.delegate];
  window.delegate = _windowDelegateProxy;

  __weak LeetCodeNavigationToolbarController *weakSelf = self;
  NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
  _willEnterFullscreenObserver = [notifications
    addObserverForName:NSWindowWillEnterFullScreenNotification
    object:window
    queue:NSOperationQueue.mainQueue
    usingBlock:^(__unused NSNotification *notification) {
      [weakSelf updateControlWidth];
      if (weakSelf.navigationActive) weakSelf.toolbar.visible = YES;
    }];
  _didEnterFullscreenObserver = [notifications
    addObserverForName:NSWindowDidEnterFullScreenNotification
    object:window
    queue:NSOperationQueue.mainQueue
    usingBlock:^(__unused NSNotification *notification) {
      [weakSelf updateControlWidth];
    }];
  _windowResizeObserver = [notifications
    addObserverForName:NSWindowDidResizeNotification
    object:window
    queue:NSOperationQueue.mainQueue
    usingBlock:^(__unused NSNotification *notification) {
      [weakSelf updateControlWidth];
    }];
  _windowScreenObserver = [notifications
    addObserverForName:NSWindowDidChangeScreenNotification
    object:window
    queue:NSOperationQueue.mainQueue
    usingBlock:^(__unused NSNotification *notification) {
      [weakSelf updateControlWidth];
    }];
  _windowBackingObserver = [notifications
    addObserverForName:NSWindowDidChangeBackingPropertiesNotification
    object:window
    queue:NSOperationQueue.mainQueue
    usingBlock:^(__unused NSNotification *notification) {
      [weakSelf updateControlWidth];
    }];
  _didExitFullscreenObserver = [notifications
    addObserverForName:NSWindowDidExitFullScreenNotification
    object:window
    queue:NSOperationQueue.mainQueue
    usingBlock:^(__unused NSNotification *notification) {
      weakSelf.toolbar.visible = NO;
    }];
  [self updateControlWidth];
  return self;
}

- (void)updateControlWidth {
  const CGFloat windowWidth = NSWidth(self.window.contentView.bounds);
  self.navigationControl.preferredWidth = MIN(680.0, MAX(320.0, windowWidth * 0.58));
}

- (void)updateToolbarVisibility {
  const BOOL fullscreen = (self.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
  self.toolbar.visible = self.navigationActive && fullscreen;
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
  return @[LeetCodeNavigationItemIdentifier];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
  return @[LeetCodeNavigationItemIdentifier];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
     itemForItemIdentifier:(NSToolbarItemIdentifier)itemIdentifier
 willBeInsertedIntoToolbar:(BOOL)willBeInserted {
  if ([itemIdentifier isEqualToString:LeetCodeNavigationItemIdentifier]) {
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:itemIdentifier];
    item.label = @"学习区域";
    item.paletteLabel = @"学习区域";
    item.toolTip = @"切换学习区域";
    item.view = self.navigationControl;
    return item;
  }
  return nil;
}

- (void)selectLearningRegion:(LeetCodeLiquidSegmentedControl *)sender {
  static const char *actions[] = {"today", "leetcode", "library", "insights"};
  const NSInteger segment = sender.selectedSegment;
  if (segment >= 0 && segment < 4) DispatchNavigationCommand(actions[segment]);
}

- (void)setSelectedSegment:(NSInteger)segment {
  self.navigationActive = segment >= 0 && segment <= 3;
  self.navigationControl.selectedSegment = self.navigationActive ? segment : -1;
  [self updateToolbarVisibility];
}

- (void)uninstall {
  NSNotificationCenter *notifications = NSNotificationCenter.defaultCenter;
  if (self.willEnterFullscreenObserver) {
    [notifications removeObserver:self.willEnterFullscreenObserver];
    self.willEnterFullscreenObserver = nil;
  }
  if (self.windowResizeObserver) {
    [notifications removeObserver:self.windowResizeObserver];
    self.windowResizeObserver = nil;
  }
  if (self.didEnterFullscreenObserver) {
    [notifications removeObserver:self.didEnterFullscreenObserver];
    self.didEnterFullscreenObserver = nil;
  }
  if (self.windowScreenObserver) {
    [notifications removeObserver:self.windowScreenObserver];
    self.windowScreenObserver = nil;
  }
  if (self.windowBackingObserver) {
    [notifications removeObserver:self.windowBackingObserver];
    self.windowBackingObserver = nil;
  }
  if (self.didExitFullscreenObserver) {
    [notifications removeObserver:self.didExitFullscreenObserver];
    self.didExitFullscreenObserver = nil;
  }
  if (self.window.delegate == self.windowDelegateProxy) {
    self.window.delegate = self.windowDelegateProxy.originalDelegate;
  }
  if (self.window.toolbar == self.toolbar) self.window.toolbar = nil;
}

@end

static LeetCodeNavigationToolbarController *gNavigationToolbarController = nil;

namespace {

void CallSelectionCallback(
  Napi::Env env,
  Napi::Function callback,
  std::nullptr_t *,
  std::string *text
);

using SelectionThreadSafeFunction = Napi::TypedThreadSafeFunction<
  std::nullptr_t,
  std::string,
  CallSelectionCallback
>;

id gSelectionEventMonitor = nil;
std::unique_ptr<SelectionThreadSafeFunction> gSelectionCallback;
std::string gLastDeliveredText;
CFAbsoluteTime gLastDeliveryTime = 0;
NSPoint gLeftMouseDownLocation = NSZeroPoint;
uint64_t gSelectionGeneration = 0;

constexpr int64_t kClipboardPollIntervalMs = 25;
constexpr int kClipboardPollAttempts = 16;
constexpr size_t kSelectionCallbackQueueSize = 32;

void CallSelectionCallback(
  Napi::Env env,
  Napi::Function callback,
  std::nullptr_t *,
  std::string *text
) {
  std::unique_ptr<std::string> ownedText(text);
  if (env == nullptr || callback.IsEmpty()) return;
  callback.Call({Napi::String::New(env, *ownedText)});
}

NSView *ViewFromHandle(const Napi::Value &value) {
  if (!value.IsBuffer()) return nil;

  Napi::Buffer<uint8_t> buffer = value.As<Napi::Buffer<uint8_t>>();
  if (buffer.Length() < sizeof(void *)) return nil;

  void *pointer = nullptr;
  memcpy(&pointer, buffer.Data(), sizeof(void *));
  return (__bridge NSView *)pointer;
}

NSString *CopySelectedText() {
  AXUIElementRef systemElement = AXUIElementCreateSystemWide();
  if (!systemElement) return nil;
  AXUIElementSetMessagingTimeout(systemElement, 0.25);

  CFTypeRef focusedValue = nullptr;
  AXError focusedError = AXUIElementCopyAttributeValue(
    systemElement,
    kAXFocusedUIElementAttribute,
    &focusedValue
  );
  CFRelease(systemElement);
  if (focusedError != kAXErrorSuccess || !focusedValue) return nil;

  AXUIElementSetMessagingTimeout(static_cast<AXUIElementRef>(focusedValue), 0.25);

  CFTypeRef selectedValue = nullptr;
  AXError selectedError = AXUIElementCopyAttributeValue(
    static_cast<AXUIElementRef>(focusedValue),
    kAXSelectedTextAttribute,
    &selectedValue
  );
  CFRelease(focusedValue);
  if (selectedError != kAXErrorSuccess || !selectedValue) return nil;

  NSString *selectedText = nil;
  if (CFGetTypeID(selectedValue) == CFStringGetTypeID()) {
    selectedText = [(__bridge NSString *)selectedValue copy];
  }
  CFRelease(selectedValue);

  NSString *trimmed = [selectedText stringByTrimmingCharactersInSet:
    NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return trimmed.length > 0 ? trimmed : nil;
}

NSGlassEffectView *CreateGlassView(NSString *identifier, CGFloat cornerRadius, NSColor *tintColor) {
  NSGlassEffectView *glass = [[LeetCodeGlassEffectView alloc] initWithFrame:NSZeroRect];
  glass.identifier = identifier;
  glass.translatesAutoresizingMaskIntoConstraints = NO;
  glass.style = NSGlassEffectViewStyleRegular;
  glass.cornerRadius = cornerRadius;
  glass.tintColor = tintColor;
  if (@available(macOS 27.0, *)) glass.effectIsInteractive = NO;
  return glass;
}

void RemoveExistingGlassViews(NSView *rootView) {
  NSArray<NSView *> *subviews = [rootView.subviews copy];
  for (NSView *subview in subviews) {
    if ([subview.identifier hasPrefix:@"LeetCodeGlass"]) {
      [subview removeFromSuperview];
    }
  }
}

void AddBehindWebContent(NSView *rootView, NSView *glass) {
  NSView *frontmostExistingView = rootView.subviews.firstObject;
  if (frontmostExistingView) {
    [rootView addSubview:glass positioned:NSWindowBelow relativeTo:frontmostExistingView];
  } else {
    [rootView addSubview:glass];
  }
}

bool ApplyGlass(NSView *nativeView, bool fullWindow, bool blueTint) {
  NSWindow *window = nativeView.window;
  NSView *rootView = window.contentView;
  if (!window || !rootView) return false;

  if (@available(macOS 26.0, *)) {
    RemoveExistingGlassViews(rootView);
    NSColor *tintColor = blueTint
      ? [NSColor colorWithSRGBRed:0.20 green:0.62 blue:1.0 alpha:0.14]
      : [NSColor colorWithSRGBRed:1.0 green:1.0 blue:1.0 alpha:0.28];
    const CGFloat cornerRadius = blueTint ? 19.0 : 14.0;

    if (fullWindow) {
      NSGlassEffectView *glass = CreateGlassView(@"LeetCodeGlassFull", cornerRadius, tintColor);
      AddBehindWebContent(rootView, glass);
      [NSLayoutConstraint activateConstraints:@[
        [glass.leadingAnchor constraintEqualToAnchor:rootView.leadingAnchor],
        [glass.trailingAnchor constraintEqualToAnchor:rootView.trailingAnchor],
        [glass.topAnchor constraintEqualToAnchor:rootView.topAnchor],
        [glass.bottomAnchor constraintEqualToAnchor:rootView.bottomAnchor]
      ]];
    } else {
      NSGlassEffectView *topGlass = CreateGlassView(@"LeetCodeGlassTop", cornerRadius, tintColor);
      NSGlassEffectView *bottomGlass = CreateGlassView(@"LeetCodeGlassBottom", cornerRadius, tintColor);
      AddBehindWebContent(rootView, topGlass);
      AddBehindWebContent(rootView, bottomGlass);
      [NSLayoutConstraint activateConstraints:@[
        [topGlass.leadingAnchor constraintEqualToAnchor:rootView.leadingAnchor],
        [topGlass.trailingAnchor constraintEqualToAnchor:rootView.trailingAnchor],
        [topGlass.topAnchor constraintEqualToAnchor:rootView.topAnchor],
        [topGlass.heightAnchor constraintEqualToConstant:42.0],
        [bottomGlass.leadingAnchor constraintEqualToAnchor:rootView.leadingAnchor],
        [bottomGlass.trailingAnchor constraintEqualToAnchor:rootView.trailingAnchor],
        [bottomGlass.bottomAnchor constraintEqualToAnchor:rootView.bottomAnchor],
        [bottomGlass.heightAnchor constraintEqualToConstant:58.0]
      ]];
    }
  } else {
    return false;
  }

  window.opaque = NO;
  window.backgroundColor = NSColor.clearColor;
  window.hasShadow = YES;
  // Electron owns window level and workspace visibility. Mutating collection
  // behavior here made an unpinned window follow every Space after glass was
  // applied, until the user toggled the pin twice.

  if ([window isKindOfClass:[NSPanel class]]) {
    ((NSPanel *)window).hidesOnDeactivate = NO;
  }

  for (NSView *subview in rootView.subviews) {
    if ([subview.identifier hasPrefix:@"LeetCodeGlass"]) return true;
  }
  return false;
}

bool IsAccessibilityTrusted(bool prompt) {
  NSDictionary *options = @{
    (__bridge NSString *)kAXTrustedCheckOptionPrompt: @(prompt)
  };
  return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options);
}

void DeliverText(NSString *text) {
  if (!gSelectionCallback) return;

  NSString *trimmed = [text stringByTrimmingCharactersInSet:
    NSCharacterSet.whitespaceAndNewlineCharacterSet];
  std::string value(trimmed.UTF8String ?: "");
  const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (!value.empty() && value == gLastDeliveredText && now - gLastDeliveryTime < 0.8) return;
  gLastDeliveredText = value;
  gLastDeliveryTime = now;

  auto *payload = new std::string(std::move(value));
  napi_status status = gSelectionCallback->NonBlockingCall(payload);
  if (status != napi_ok) delete payload;
}

void NotifySelectionCleared() {
  if (!gSelectionCallback) return;

  auto *payload = new std::string();
  napi_status status = gSelectionCallback->NonBlockingCall(payload);
  if (status != napi_ok) delete payload;
  if (status != napi_ok && status != napi_closing) {
    NSLog(@"Selection clear callback failed with status %d", status);
  }
}

NSArray<NSDictionary<NSPasteboardType, NSData *> *> *SnapshotPasteboard(NSPasteboard *pasteboard) {
  NSMutableArray *snapshot = [NSMutableArray array];
  for (NSPasteboardItem *item in pasteboard.pasteboardItems ?: @[]) {
    NSMutableDictionary *storedItem = [NSMutableDictionary dictionary];
    for (NSPasteboardType type in item.types) {
      NSData *data = [item dataForType:type];
      if (data) storedItem[type] = data;
    }
    if (storedItem.count) [snapshot addObject:storedItem];
  }
  return snapshot;
}

void RestorePasteboard(
  NSPasteboard *pasteboard,
  NSArray<NSDictionary<NSPasteboardType, NSData *> *> *snapshot
) {
  [pasteboard clearContents];
  NSMutableArray<NSPasteboardItem *> *items = [NSMutableArray array];
  for (NSDictionary<NSPasteboardType, NSData *> *storedItem in snapshot) {
    NSPasteboardItem *item = [[NSPasteboardItem alloc] init];
    for (NSPasteboardType type in storedItem) {
      [item setData:storedItem[type] forType:type];
    }
    [items addObject:item];
  }
  if (items.count) [pasteboard writeObjects:items];
}

void RestorePasteboardIfUnchanged(
  NSPasteboard *pasteboard,
  NSArray<NSDictionary<NSPasteboardType, NSData *> *> *snapshot,
  NSInteger expectedChangeCount
) {
  if (pasteboard.changeCount == expectedChangeCount) {
    RestorePasteboard(pasteboard, snapshot);
  }
}

void PollBrowserSelection(
  NSPasteboard *pasteboard,
  NSArray<NSDictionary<NSPasteboardType, NSData *> *> *snapshot,
  NSInteger clearedChangeCount,
  uint64_t generation,
  int attemptsRemaining
) {
  const NSInteger currentChangeCount = pasteboard.changeCount;
  if (currentChangeCount != clearedChangeCount) {
    NSString *selectedText = [pasteboard stringForType:NSPasteboardTypeString];
    RestorePasteboardIfUnchanged(pasteboard, snapshot, currentChangeCount);
    if (generation == gSelectionGeneration) DeliverText(selectedText);
    return;
  }

  if (generation != gSelectionGeneration || attemptsRemaining <= 0) {
    RestorePasteboardIfUnchanged(pasteboard, snapshot, clearedChangeCount);
    return;
  }

  dispatch_after(
    dispatch_time(DISPATCH_TIME_NOW, kClipboardPollIntervalMs * NSEC_PER_MSEC),
    dispatch_get_main_queue(),
    ^{
      PollBrowserSelection(
        pasteboard,
        snapshot,
        clearedChangeCount,
        generation,
        attemptsRemaining - 1
      );
    }
  );
}

void CopyBrowserSelection(uint64_t generation) {
  if (generation != gSelectionGeneration) return;

  NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
  NSArray *snapshot = SnapshotPasteboard(pasteboard);
  [pasteboard clearContents];
  const NSInteger clearedChangeCount = pasteboard.changeCount;

  CGEventRef keyDown = CGEventCreateKeyboardEvent(nullptr, 8, true);
  CGEventRef keyUp = CGEventCreateKeyboardEvent(nullptr, 8, false);
  if (!keyDown || !keyUp) {
    if (keyDown) CFRelease(keyDown);
    if (keyUp) CFRelease(keyUp);
    RestorePasteboardIfUnchanged(pasteboard, snapshot, clearedChangeCount);
    return;
  }
  CGEventSetFlags(keyDown, kCGEventFlagMaskCommand);
  CGEventSetFlags(keyUp, kCGEventFlagMaskCommand);
  CGEventPost(kCGHIDEventTap, keyDown);
  CGEventPost(kCGHIDEventTap, keyUp);
  CFRelease(keyDown);
  CFRelease(keyUp);

  PollBrowserSelection(
    pasteboard,
    snapshot,
    clearedChangeCount,
    generation,
    kClipboardPollAttempts
  );
}

void DeliverSelectedText(bool allowClipboardFallback, uint64_t generation) {
  if (generation != gSelectionGeneration) return;

  NSString *selectedText = CopySelectedText();
  if (selectedText.length || !allowClipboardFallback) {
    if (generation == gSelectionGeneration) DeliverText(selectedText);
    return;
  }
  CopyBrowserSelection(generation);
}

Napi::Value Apply(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (info.Length() < 1) {
    Napi::TypeError::New(env, "window handle is required").ThrowAsJavaScriptException();
    return env.Undefined();
  }

  NSView *nativeView = ViewFromHandle(info[0]);
  if (!nativeView) {
    Napi::TypeError::New(env, "invalid window handle").ThrowAsJavaScriptException();
    return env.Undefined();
  }

  const bool fullWindow = info.Length() > 1 && info[1].ToBoolean().Value();
  const bool blueTint = info.Length() > 2 && info[2].IsString()
    && info[2].As<Napi::String>().Utf8Value() == "blue";
  __block bool applied = false;
  if (NSThread.isMainThread) {
    applied = ApplyGlass(nativeView, fullWindow, blueTint);
  } else {
    dispatch_sync(dispatch_get_main_queue(), ^{
      applied = ApplyGlass(nativeView, fullWindow, blueTint);
    });
  }

  return Napi::Boolean::New(env, applied);
}

Napi::Value RequestAccessibility(const Napi::CallbackInfo &info) {
  return Napi::Boolean::New(info.Env(), IsAccessibilityTrusted(true));
}

Napi::Value IsAccessibilityEnabled(const Napi::CallbackInfo &info) {
  return Napi::Boolean::New(info.Env(), IsAccessibilityTrusted(false));
}

Napi::Value GetSelectedText(const Napi::CallbackInfo &info) {
  NSString *selectedText = CopySelectedText();
  if (!selectedText.length) return info.Env().Null();
  return Napi::String::New(info.Env(), selectedText.UTF8String ?: "");
}

Napi::Value StartSelectionMonitor(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (info.Length() < 1 || !info[0].IsFunction()) {
    Napi::TypeError::New(env, "callback is required").ThrowAsJavaScriptException();
    return env.Undefined();
  }
  if (!IsAccessibilityTrusted(false)) return Napi::Boolean::New(env, false);
  if (gSelectionEventMonitor) return Napi::Boolean::New(env, true);

  gSelectionCallback = std::make_unique<SelectionThreadSafeFunction>(
    SelectionThreadSafeFunction::New(
      env,
      info[0].As<Napi::Function>(),
      "selected-text-monitor",
      kSelectionCallbackQueueSize,
      1
    )
  );

  const NSEventMask selectionEvents = NSEventMaskLeftMouseDown
    | NSEventMaskLeftMouseUp
    | NSEventMaskRightMouseDown
    | NSEventMaskKeyUp;
  gSelectionEventMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:selectionEvents
    handler:^(NSEvent *event) {
      if (event.type == NSEventTypeLeftMouseDown) {
        ++gSelectionGeneration;
        gLeftMouseDownLocation = NSEvent.mouseLocation;
        NotifySelectionCleared();
        return;
      }

      bool shouldReadSelection = event.type == NSEventTypeLeftMouseUp
        || event.type == NSEventTypeRightMouseDown;
      bool allowClipboardFallback = false;

      if (event.type == NSEventTypeLeftMouseUp) {
        const NSPoint mouseUpLocation = NSEvent.mouseLocation;
        const CGFloat dx = mouseUpLocation.x - gLeftMouseDownLocation.x;
        const CGFloat dy = mouseUpLocation.y - gLeftMouseDownLocation.y;
        const bool extendsSelection = event.modifierFlags & NSEventModifierFlagShift;
        allowClipboardFallback = event.clickCount >= 2
          || dx * dx + dy * dy >= 16.0
          || extendsSelection;
        shouldReadSelection = allowClipboardFallback;
      }

      if (event.type == NSEventTypeKeyUp) {
        const NSEventModifierFlags flags = event.modifierFlags
          & NSEventModifierFlagDeviceIndependentFlagsMask;
        const unsigned short keyCode = event.keyCode;
        const bool navigationKey = keyCode == 115 || keyCode == 116
          || keyCode == 119 || keyCode == 121
          || (keyCode >= 123 && keyCode <= 126);
        const bool selectAll = (flags & NSEventModifierFlagCommand) && keyCode == 0;
        shouldReadSelection = selectAll
          || ((flags & NSEventModifierFlagShift) && navigationKey);
        allowClipboardFallback = shouldReadSelection;
      }

      if (!shouldReadSelection) return;
      const uint64_t generation = ++gSelectionGeneration;
      const int64_t delay = event.type == NSEventTypeLeftMouseUp ? 140 : 90;
      dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_MSEC),
        dispatch_get_main_queue(),
        ^{ DeliverSelectedText(allowClipboardFallback, generation); }
      );
    }];

  if (!gSelectionEventMonitor) {
    gSelectionCallback->Release();
    gSelectionCallback.reset();
  }

  return Napi::Boolean::New(env, gSelectionEventMonitor != nil);
}

Napi::Value StopSelectionMonitor(const Napi::CallbackInfo &info) {
  if (gSelectionEventMonitor) {
    [NSEvent removeMonitor:gSelectionEventMonitor];
    gSelectionEventMonitor = nil;
  }
  ++gSelectionGeneration;
  gLastDeliveredText.clear();
  gLastDeliveryTime = 0;
  if (gSelectionCallback) {
    gSelectionCallback->Release();
    gSelectionCallback.reset();
  }
  return info.Env().Undefined();
}

Napi::Value InstallNavigationToolbar(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (info.Length() < 2 || !info[1].IsFunction()) {
    Napi::TypeError::New(env, "window handle and callback are required")
      .ThrowAsJavaScriptException();
    return env.Undefined();
  }

  NSView *nativeView = ViewFromHandle(info[0]);
  NSWindow *window = nativeView.window;
  if (!nativeView || !window) {
    Napi::TypeError::New(env, "invalid window handle").ThrowAsJavaScriptException();
    return env.Undefined();
  }

  if (gNavigationCallback) {
    gNavigationCallback->Abort();
    gNavigationCallback.reset();
  }
  gNavigationCallback = std::make_unique<NavigationThreadSafeFunction>(
    NavigationThreadSafeFunction::New(
      env,
      info[1].As<Napi::Function>(),
      "native-navigation-toolbar",
      8,
      1
    )
  );

  __block bool installed = false;
  void (^install)(void) = ^{
    [gNavigationToolbarController uninstall];
    gNavigationToolbarController = [[LeetCodeNavigationToolbarController alloc] initWithWindow:window];
    installed = gNavigationToolbarController != nil;
  };
  if (NSThread.isMainThread) install();
  else dispatch_sync(dispatch_get_main_queue(), install);
  return Napi::Boolean::New(env, installed);
}

Napi::Value SetNavigationToolbarSelection(const Napi::CallbackInfo &info) {
  Napi::Env env = info.Env();
  if (info.Length() < 1 || (!info[0].IsString() && !info[0].IsNull())) {
    Napi::TypeError::New(env, "navigation action must be a string or null")
      .ThrowAsJavaScriptException();
    return env.Undefined();
  }

  NSInteger segment = -1;
  if (info[0].IsString()) {
    const std::string action = info[0].As<Napi::String>().Utf8Value();
    if (action == "today") segment = 0;
    else if (action == "leetcode") segment = 1;
    else if (action == "library" || action == "knowledge" || action == "templates") segment = 2;
    else if (action == "insights") segment = 3;
  }

  void (^update)(void) = ^{ [gNavigationToolbarController setSelectedSegment:segment]; };
  if (NSThread.isMainThread) update();
  else dispatch_sync(dispatch_get_main_queue(), update);
  return Napi::Boolean::New(env, gNavigationToolbarController != nil);
}

void CleanupAddon() {
  if (gSelectionEventMonitor) {
    [NSEvent removeMonitor:gSelectionEventMonitor];
    gSelectionEventMonitor = nil;
  }
  ++gSelectionGeneration;
  if (gSelectionCallback) {
    gSelectionCallback->Abort();
    gSelectionCallback.reset();
  }
  [gNavigationToolbarController uninstall];
  gNavigationToolbarController = nil;
  if (gNavigationCallback) {
    gNavigationCallback->Abort();
    gNavigationCallback.reset();
  }
}

Napi::Object Init(Napi::Env env, Napi::Object exports) {
  env.AddCleanupHook(CleanupAddon);
  exports.Set("apply", Napi::Function::New(env, Apply));
  exports.Set("requestAccessibility", Napi::Function::New(env, RequestAccessibility));
  exports.Set("isAccessibilityEnabled", Napi::Function::New(env, IsAccessibilityEnabled));
  exports.Set("getSelectedText", Napi::Function::New(env, GetSelectedText));
  exports.Set("startSelectionMonitor", Napi::Function::New(env, StartSelectionMonitor));
  exports.Set("stopSelectionMonitor", Napi::Function::New(env, StopSelectionMonitor));
  exports.Set("installNavigationToolbar", Napi::Function::New(env, InstallNavigationToolbar));
  exports.Set("setNavigationToolbarSelection", Napi::Function::New(env, SetNavigationToolbarSelection));
  return exports;
}

}  // namespace

NODE_API_MODULE(liquid_glass, Init)
