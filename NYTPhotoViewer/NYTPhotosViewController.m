//
//  NYTPhotosViewController.m
//  NYTPhotoViewer
//
//  Created by Brian Capps on 2/10/15.
//  Copyright (c) 2015 NYTimes. All rights reserved.
//

#import "NYTPhotosViewController.h"
#import "NYTPhotoViewerDataSource.h"
#import "NYTPhotoViewerArrayDataSource.h"
#import "NYTPhotoViewController.h"
#import "NYTPhotoTransitionController.h"
#import "NYTScalingImageView.h"
#import "NYTPhoto.h"
#import "NYTPhotosOverlayView.h"
#import "NYTPhotoCaptionView.h"
#import "NSBundle+NYTPhotoViewer.h"
#import "MerryPhoto.h"
#ifdef ANIMATED_GIF_SUPPORT
#import <FLAnimatedImage/FLAnimatedImage.h>
#endif

NSString * const NYTPhotosViewControllerDidNavigateToPhotoNotification = @"NYTPhotosViewControllerDidNavigateToPhotoNotification";
NSString * const NYTPhotosViewControllerWillDismissNotification = @"NYTPhotosViewControllerWillDismissNotification";
NSString * const NYTPhotosViewControllerDidDismissNotification = @"NYTPhotosViewControllerDidDismissNotification";

static const CGFloat NYTPhotosViewControllerOverlayAnimationDuration = 0.2;
static const CGFloat NYTPhotosViewControllerInterPhotoSpacing = 16.0;
static const UIEdgeInsets NYTPhotosViewControllerCloseButtonImageInsets = {3, 0, -3, 0};

@interface NYTPhotosViewController () <UIPageViewControllerDataSource, UIPageViewControllerDelegate, NYTPhotoViewControllerDelegate>

- (instancetype)initWithCoder:(NSCoder *)aDecoder NS_DESIGNATED_INITIALIZER;

@property (nonatomic) UIPageViewController *pageViewController;
@property (nonatomic) NYTPhotoTransitionController *transitionController;
@property (nonatomic) UIPopoverController *activityPopoverController;

@property (nonatomic) UIPanGestureRecognizer *panGestureRecognizer;
@property (nonatomic) UITapGestureRecognizer *singleTapGestureRecognizer;

@property (nonatomic) NYTPhotosOverlayView *overlayView;

/// A custom notification center to scope internal notifications to this `NYTPhotosViewController` instance.
@property (nonatomic) NSNotificationCenter *notificationCenter;

@property (nonatomic) BOOL shouldHandleLongPress;
@property (nonatomic) BOOL overlayWasHiddenBeforeTransition;

@property (nonatomic, readonly) NYTPhotoViewController *currentPhotoViewController;
@property (nonatomic, readonly) UIView *referenceViewForCurrentPhoto;
@property (nonatomic, readonly) CGPoint boundsCenterPoint;

@property (nonatomic, nullable) id<NYTPhoto> initialPhoto;

@end

@implementation NYTPhotosViewController
{
    UIBarButtonItem *sharebarBtn;
}

#pragma mark - NSObject

- (void)dealloc {
    _pageViewController.dataSource = nil;
    _pageViewController.delegate = nil;
}

#pragma mark - NSObject(UIResponderStandardEditActions)

- (void)copy:(id)sender {
    [[UIPasteboard generalPasteboard] setImage:self.currentlyDisplayedPhoto.image];
}

#pragma mark - UIResponder

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (self.shouldHandleLongPress && action == @selector(copy:) && self.currentlyDisplayedPhoto.image) {
        return YES;
    }
    
    return NO;
}

#pragma mark - UIViewController

- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    return [self initWithDataSource:[NYTPhotoViewerArrayDataSource dataSourceWithPhotos:@[]] initialPhoto:nil delegate:nil];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];
    
    if (self) {
        [self commonInitWithDataSource:[NYTPhotoViewerArrayDataSource dataSourceWithPhotos:@[]] initialPhoto:nil delegate:nil];
    }
    
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [self configurePageViewControllerWithInitialPhoto];
    
    self.view.tintColor = [UIColor whiteColor];
    self.view.backgroundColor = [UIColor blackColor];
    self.pageViewController.view.backgroundColor = [UIColor clearColor];
    
    [self.pageViewController.view addGestureRecognizer:self.panGestureRecognizer];
    [self.pageViewController.view addGestureRecognizer:self.singleTapGestureRecognizer];
    
    [self addChildViewController:self.pageViewController];
    [self.view addSubview:self.pageViewController.view];
    [self.pageViewController didMoveToParentViewController:self];
    
    [self addOverlayView];
    
    self.transitionController.startingView = self.referenceViewForCurrentPhoto;
    
    UIView *endingView;
    if (self.currentlyDisplayedPhoto.image || self.currentlyDisplayedPhoto.placeholderImage) {
        endingView = self.currentPhotoViewController.scalingImageView.imageView;
    }
    self.transitionController.endingView = endingView;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    if (!self.overlayWasHiddenBeforeTransition) {
        [self setOverlayViewHidden:NO animated:YES];
    }
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    
    self.pageViewController.view.frame = self.view.bounds;
    self.overlayView.frame = self.view.bounds;
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

- (UIStatusBarAnimation)preferredStatusBarUpdateAnimation {
    return UIStatusBarAnimationFade;
}

- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion {
    [self dismissViewControllerAnimated:animated userInitiated:NO completion:completion];
}

#pragma mark - NYTPhotosViewController

- (instancetype)initWithDataSource:(id <NYTPhotoViewerDataSource>)dataSource {
    return [self initWithDataSource:dataSource initialPhoto:nil delegate:nil];
}

- (instancetype)initWithDataSource:(id <NYTPhotoViewerDataSource>)dataSource initialPhotoIndex:(NSInteger)initialPhotoIndex delegate:(nullable id <NYTPhotosViewControllerDelegate>)delegate {
    id <NYTPhoto> initialPhoto = [dataSource photoAtIndex:initialPhotoIndex];
    
    return [self initWithDataSource:dataSource initialPhoto:initialPhoto delegate:delegate];
}

- (instancetype)initWithDataSource:(id <NYTPhotoViewerDataSource>)dataSource initialPhoto:(id <NYTPhoto> _Nullable)initialPhoto delegate:(nullable id <NYTPhotosViewControllerDelegate>)delegate {
    self = [super initWithNibName:nil bundle:nil];
    
    if (self) {
        [self commonInitWithDataSource:dataSource initialPhoto:initialPhoto delegate:delegate];
    }
    
    return self;
}

- (void)commonInitWithDataSource:(id <NYTPhotoViewerDataSource>)dataSource initialPhoto:(id <NYTPhoto> _Nullable)initialPhoto delegate:(nullable id <NYTPhotosViewControllerDelegate>)delegate {
    _dataSource = dataSource;
    _delegate = delegate;
    _initialPhoto = initialPhoto;
    
    _panGestureRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(didPanWithGestureRecognizer:)];
    _singleTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(didSingleTapWithGestureRecognizer:)];
    
    _transitionController = [[NYTPhotoTransitionController alloc] init];
    self.modalPresentationStyle = UIModalPresentationCustom;
    self.transitioningDelegate = _transitionController;
    self.modalPresentationCapturesStatusBarAppearance = YES;
    
    _overlayView = ({
        NYTPhotosOverlayView *v = [[NYTPhotosOverlayView alloc] initWithFrame:CGRectZero];
        v.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"NYTPhotoViewerCloseButtonX" inBundle:[NSBundle nyt_photoViewerResourceBundle] compatibleWithTraitCollection:nil] landscapeImagePhone:[UIImage imageNamed:@"NYTPhotoViewerCloseButtonXLandscape" inBundle:[NSBundle nyt_photoViewerResourceBundle] compatibleWithTraitCollection:nil] style:UIBarButtonItemStylePlain target:self action:@selector(doneButtonTapped:)];
        v.leftBarButtonItem.imageInsets = NYTPhotosViewControllerCloseButtonImageInsets;
        
        ///
        UIImage *shareImage = [UIImage imageNamed:@"ic_share.png"];
        UIButton *shareBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        shareBtn.frame = CGRectMake( 0, 5, 30, 50);
        [shareBtn setImage:shareImage forState:UIControlStateNormal];
        [shareBtn addTarget:self action:@selector(shareActionTapped:) forControlEvents:UIControlEventTouchDown];
        sharebarBtn = [[UIBarButtonItem alloc] initWithCustomView:shareBtn];
        
        v.rightBarButtonItems = @[sharebarBtn];
        
        v;
    });
    
    _notificationCenter = [NSNotificationCenter new];
    
    self.pageViewController = [[UIPageViewController alloc] initWithTransitionStyle:UIPageViewControllerTransitionStyleScroll navigationOrientation:UIPageViewControllerNavigationOrientationHorizontal options:@{UIPageViewControllerOptionInterPageSpacingKey: @(NYTPhotosViewControllerInterPhotoSpacing)}];
    
    self.pageViewController.delegate = self;
    self.pageViewController.dataSource = self;
}

- (void)configurePageViewControllerWithInitialPhoto {
    NYTPhotoViewController *initialPhotoViewController;
    
    if (self.initialPhoto != nil && [self.dataSource indexOfPhoto:self.initialPhoto] != NSNotFound) {
        initialPhotoViewController = [self newPhotoViewControllerForPhoto:self.initialPhoto];
    }
    else {
        initialPhotoViewController = [self newPhotoViewControllerForPhoto:[self.dataSource photoAtIndex:0]];
    }
    
    [self setCurrentlyDisplayedViewController:initialPhotoViewController animated:NO];
}

- (void)addOverlayView {
    NSAssert(self.overlayView != nil, @"_overlayView must be set during initialization, to provide bar button items for this %@", NSStringFromClass([self class]));
    
    UIColor *textColor = self.view.tintColor ?: [UIColor whiteColor];
    self.overlayView.titleTextAttributes = @{NSForegroundColorAttributeName: textColor};
    
    [self updateOverlayInformation];
    [self.view addSubview:self.overlayView];
    
    [self setOverlayViewHidden:YES animated:NO];
}


- (void)updateOverlayInformation {
    NSString *overlayTitle;
    NSUInteger photoIndex = [self.dataSource indexOfPhoto:self.currentlyDisplayedPhoto];
    NSInteger displayIndex = photoIndex + 1;
    
    if ([self.delegate respondsToSelector:@selector(photosViewController:titleForPhoto:atIndex:totalPhotoCount:)]) {
        overlayTitle = [self.delegate photosViewController:self titleForPhoto:self.currentlyDisplayedPhoto atIndex:photoIndex totalPhotoCount:self.dataSource.numberOfPhotos];
    }
    
    if (!overlayTitle && self.dataSource.numberOfPhotos == nil) {
        overlayTitle = [NSString localizedStringWithFormat:@"%lu", (unsigned long)displayIndex];
    }
    
    if (!overlayTitle && self.dataSource.numberOfPhotos.integerValue > 1) {
        overlayTitle = [NSString localizedStringWithFormat:NSLocalizedString(@"%lu of %lu", nil), (unsigned long)displayIndex, (unsigned long)self.dataSource.numberOfPhotos.integerValue];
    }
    
    self.overlayView.title = overlayTitle;
    
    UIView *captionView;
    if ([self.delegate respondsToSelector:@selector(photosViewController:captionViewForPhoto:)]) {
        captionView = [self.delegate photosViewController:self captionViewForPhoto:self.currentlyDisplayedPhoto];
    }
    
    if (!captionView) {
        captionView = [[NYTPhotoCaptionView alloc] initWithAttributedTitle:self.currentlyDisplayedPhoto.attributedCaptionTitle attributedSummary:self.currentlyDisplayedPhoto.attributedCaptionSummary attributedCredit:self.currentlyDisplayedPhoto.attributedCaptionCredit];
    }
    
    BOOL captionViewRespectsSafeArea = YES;
    if ([self.delegate respondsToSelector:@selector(photosViewController:captionViewRespectsSafeAreaForPhoto:)]) {
        captionViewRespectsSafeArea = [self.delegate photosViewController:self captionViewRespectsSafeAreaForPhoto:self.currentlyDisplayedPhoto];
    }
    
    self.overlayView.captionViewRespectsSafeArea = captionViewRespectsSafeArea;
    self.overlayView.captionView = captionView;
    
    NSMutableArray* additionalButtonItems = [[NSMutableArray alloc] init];
    
    // Add aditional buttons
    if ([self.delegate respondsToSelector:@selector(photosViewController:isCollectEnabled:)] && [self.delegate photosViewController:self isCollectEnabled:self.currentlyDisplayedPhoto]) {
        UIImage *shareImage = [UIImage imageNamed:@"icon_photo_notcollected.png"];
        if (self.currentlyDisplayedPhoto.isCollected) {
            shareImage = [UIImage imageNamed:@"icon_photo_collected.png"];
        }
        
        UIButton *collectButton = [UIButton buttonWithType:UIButtonTypeCustom];
        collectButton.frame = CGRectMake( 0, 5, 30, 30);
        collectButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
        [collectButton setImage:shareImage forState:UIControlStateNormal];
        [collectButton addTarget:self action:@selector(collectUncollectActionTapped:) forControlEvents:UIControlEventTouchDown];
        [additionalButtonItems addObject:collectButton];
    }
    
    // Add aditional buttons
    if ([self.delegate respondsToSelector:@selector(photosViewController:isSimilarImagesEnabled:)] && [self.delegate photosViewController:self isSimilarImagesEnabled:self.currentlyDisplayedPhoto]) {
        UIImage *similarImagesImage = [UIImage imageNamed:@"icon_similar_images.png"];
        UIButton *similarImagesButton = [UIButton buttonWithType:UIButtonTypeCustom];
        similarImagesButton.frame = CGRectMake( 0, 5, 30, 30);
        similarImagesButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
        [similarImagesButton setImage:similarImagesImage forState:UIControlStateNormal];
        [similarImagesButton addTarget:self action:@selector(similarImagesActionTapped:) forControlEvents:UIControlEventTouchDown];
        [additionalButtonItems addObject:similarImagesButton];
    }
    
    // Add aditional buttons
    if ([self.delegate respondsToSelector:@selector(photosViewController:isDownloadEnabled:)] && [self.delegate photosViewController:self isDownloadEnabled:self.currentlyDisplayedPhoto]) {
        UIImage *downloadImage = [UIImage imageNamed:@"icon_download_image.png"];
        UIButton *downloadButton = [UIButton buttonWithType:UIButtonTypeCustom];
        downloadButton.frame = CGRectMake( 0, 5, 30, 30);
        downloadButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
        [downloadButton setImage:downloadImage forState:UIControlStateNormal];
        [downloadButton addTarget:self action:@selector(downloadActionTapped:) forControlEvents:UIControlEventTouchDown];
        [additionalButtonItems addObject:downloadButton];
    }
    
    self.overlayView.additionalButtonItems = additionalButtonItems;
}

- (void)doneButtonTapped:(id)sender {
    [self dismissViewControllerAnimated:YES userInitiated:YES completion:nil];
}

- (void)shareActionTapped:(id)sender {
    BOOL clientDidHandle = NO;
    
    NSUInteger photoIndex = [self.dataSource indexOfPhoto:self.currentlyDisplayedPhoto];
    id<NYTPhoto> photo = [self.dataSource photoAtIndex:photoIndex];
    
    if ([self.delegate respondsToSelector:@selector(photosViewController:handleActionButtonTappedForPhoto:)]) {
        clientDidHandle = [self.delegate photosViewController:self handleActionButtonTappedForPhoto:self.currentlyDisplayedPhoto];
    }
    
    if (!clientDidHandle && (self.currentlyDisplayedPhoto.image || self.currentlyDisplayedPhoto.imageData)) {
        //UIImage *image = self.currentlyDisplayedPhoto.image ? self.currentlyDisplayedPhoto.image : [UIImage imageWithData:self.currentlyDisplayedPhoto.imageData];
        NSURL *imageURL = [NSURL URLWithString:photo.imageURL];
        UIActivityViewController *activityViewController = [[UIActivityViewController alloc] initWithActivityItems:@[imageURL] applicationActivities:nil];
        activityViewController.popoverPresentationController.barButtonItem = sharebarBtn;
        activityViewController.completionWithItemsHandler = ^(NSString * __nullable activityType, BOOL completed, NSArray * __nullable returnedItems, NSError * __nullable activityError) {
            if (completed && [self.delegate respondsToSelector:@selector(photosViewController:actionCompletedWithActivityType:)]) {
                [self.delegate photosViewController:self actionCompletedWithActivityType:activityType];
            }
        };
        [self displayActivityViewController:activityViewController animated:YES];
        
        if ([self.delegate respondsToSelector:@selector(photosViewController:didClickShare:withPhotoIndex:)]) {
            [self.delegate photosViewController:self didClickShare:photo withPhotoIndex:photoIndex];
        }
    }
}

- (void)collectUncollectActionTapped:(id)sender {
    NSUInteger photoIndex = [self.dataSource indexOfPhoto:self.currentlyDisplayedPhoto];
    if (self.currentlyDisplayedPhoto.isCollected) {
        if ([self.delegate respondsToSelector:@selector(photosViewController:didClickUncollectPhoto:withPhotoIndex:)]) {
            [self.delegate photosViewController:self didClickUncollectPhoto:self.currentlyDisplayedPhoto withPhotoIndex:photoIndex];
        }
    } else {
        if ([self.delegate respondsToSelector:@selector(photosViewController:didClickCollectPhoto:withPhotoIndex:)]) {
            [self.delegate photosViewController:self didClickCollectPhoto: self.currentlyDisplayedPhoto withPhotoIndex:photoIndex];
        }
    }
    
    if ([self.delegate respondsToSelector:@selector(photosViewController:shouldDismissOnCollect:)] && [self.delegate photosViewController: self shouldDismissOnCollect: self.currentlyDisplayedPhoto]) {
        [self doneButtonTapped: nil];
    }
    
    // Update is collected
    self.currentlyDisplayedPhoto.isCollected = !self.currentlyDisplayedPhoto.isCollected;
    
    // Update overlay view
    [self updateOverlayInformation];
}

- (void)similarImagesActionTapped:(id)sender {
    NSUInteger photoIndex = [self.dataSource indexOfPhoto:self.currentlyDisplayedPhoto];
    if ([self.delegate respondsToSelector:@selector(photosViewController:didClickSimilarImages:withPhotoIndex:)]) {
        [self.delegate photosViewController:self didClickSimilarImages: self.currentlyDisplayedPhoto  withPhotoIndex: photoIndex];
    }
}
- (void)downloadActionTapped:(id)sender {
    NSUInteger photoIndex = [self.dataSource indexOfPhoto:self.currentlyDisplayedPhoto];
    if ([self.delegate respondsToSelector:@selector(photosViewController:didClickDownload:withPhotoIndex:)]) {
        [self.delegate photosViewController:self didClickDownload: self.currentlyDisplayedPhoto withPhotoIndex: photoIndex];
    }
}

- (void)displayActivityViewController:(UIActivityViewController *)controller animated:(BOOL)animated {
    
    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone) {
        [self presentViewController:controller animated:animated completion:nil];
    }
    else {
        controller.popoverPresentationController.barButtonItem = self.rightBarButtonItem;
        [self presentViewController:controller animated:animated completion:nil];
    }
}

- (UIBarButtonItem *)leftBarButtonItem {
    return self.overlayView.leftBarButtonItem;
}

- (void)setLeftBarButtonItem:(UIBarButtonItem *)leftBarButtonItem {
    self.overlayView.leftBarButtonItem = leftBarButtonItem;
}

- (NSArray *)leftBarButtonItems {
    return self.overlayView.leftBarButtonItems;
}

- (void)setLeftBarButtonItems:(NSArray *)leftBarButtonItems {
    self.overlayView.leftBarButtonItems = leftBarButtonItems;
}

- (UIBarButtonItem *)rightBarButtonItem {
    return self.overlayView.rightBarButtonItem;
}

- (void)setRightBarButtonItem:(UIBarButtonItem *)rightBarButtonItem {
    self.overlayView.rightBarButtonItem = rightBarButtonItem;
}

- (NSArray *)rightBarButtonItems {
    return self.overlayView.rightBarButtonItems;
}

- (void)setRightBarButtonItems:(NSArray *)rightBarButtonItems {
    self.overlayView.rightBarButtonItems = rightBarButtonItems;
}

- (void)displayPhoto:(id <NYTPhoto>)photo animated:(BOOL)animated {
    if ([self.dataSource indexOfPhoto:photo] == NSNotFound) {
        return;
    }
    
    NYTPhotoViewController *photoViewController = [self newPhotoViewControllerForPhoto:photo];
    [self setCurrentlyDisplayedViewController:photoViewController animated:animated];
    [self updateOverlayInformation];
}

- (void)updatePhotoAtIndex:(NSInteger)photoIndex {
    id<NYTPhoto> photo = [self.dataSource photoAtIndex:photoIndex];
    if (!photo) {
        return;
    }
    
    [self updatePhoto:photo];
}

- (void)updatePhoto:(id<NYTPhoto>)photo {
    if ([self.dataSource indexOfPhoto:photo] == NSNotFound) {
        return;
    }
    
    [self.notificationCenter postNotificationName:NYTPhotoViewControllerPhotoImageUpdatedNotification object:photo];
    
    if ([self.currentlyDisplayedPhoto isEqual:photo]) {
        [self updateOverlayInformation];
    }
}

- (void)reloadPhotosAnimated:(BOOL)animated {
    id<NYTPhoto> newCurrentPhoto;
    
    if ([self.dataSource indexOfPhoto:self.currentlyDisplayedPhoto] != NSNotFound) {
        newCurrentPhoto = self.currentlyDisplayedPhoto;
    } else {
        newCurrentPhoto = [self.dataSource photoAtIndex:0];
    }
    
    [self displayPhoto:newCurrentPhoto animated:animated];
    
    if (self.overlayView.hidden) {
        [self setOverlayViewHidden:NO animated:animated];
    }
}

#pragma mark - Gesture Recognizers

- (void)didSingleTapWithGestureRecognizer:(UITapGestureRecognizer *)tapGestureRecognizer {
    [self setOverlayViewHidden:!self.overlayView.hidden animated:YES];
}

- (void)didPanWithGestureRecognizer:(UIPanGestureRecognizer *)panGestureRecognizer {
    if (panGestureRecognizer.state == UIGestureRecognizerStateBegan) {
        self.transitionController.forcesNonInteractiveDismissal = NO;
        [self dismissViewControllerAnimated:YES userInitiated:YES completion:nil];
    }
    else {
        self.transitionController.forcesNonInteractiveDismissal = YES;
        [self.transitionController didPanWithPanGestureRecognizer:panGestureRecognizer viewToPan:self.pageViewController.view anchorPoint:self.boundsCenterPoint];
    }
}

#pragma mark - View Controller Dismissal

- (void)dismissViewControllerAnimated:(BOOL)animated userInitiated:(BOOL)isUserInitiated completion:(void (^)(void))completion {
    if (self.presentedViewController) {
        [super dismissViewControllerAnimated:animated completion:completion];
        return;
    }
    
    UIView *startingView;
    if (self.currentlyDisplayedPhoto.image || self.currentlyDisplayedPhoto.placeholderImage || self.currentlyDisplayedPhoto.imageData) {
        startingView = self.currentPhotoViewController.scalingImageView.imageView;
    }
    
    self.transitionController.startingView = startingView;
    self.transitionController.endingView = self.referenceViewForCurrentPhoto;
    
    self.overlayWasHiddenBeforeTransition = self.overlayView.hidden;
    [self setOverlayViewHidden:YES animated:animated];
    
    // Cocoa convention is not to call delegate methods when you do something directly in code,
    // so we'll not call delegate methods if this is a programmatic dismissal:
    BOOL const shouldSendDelegateMessages = isUserInitiated;
    
    if (shouldSendDelegateMessages && [self.delegate respondsToSelector:@selector(photosViewControllerWillDismiss:)]) {
        [self.delegate photosViewControllerWillDismiss:self];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:NYTPhotosViewControllerWillDismissNotification object:self];
    
    [super dismissViewControllerAnimated:animated completion:^{
        BOOL isStillOnscreen = self.view.window != nil; // Happens when the dismissal is canceled.
        
        if (isStillOnscreen && !self.overlayWasHiddenBeforeTransition) {
            [self setOverlayViewHidden:NO animated:YES];
        }
        
        if (!isStillOnscreen) {
            if (shouldSendDelegateMessages && [self.delegate respondsToSelector:@selector(photosViewControllerDidDismiss:)]) {
                [self.delegate photosViewControllerDidDismiss:self];
            }
            
            [[NSNotificationCenter defaultCenter] postNotificationName:NYTPhotosViewControllerDidDismissNotification object:self];
        }
        
        if (completion) {
            completion();
        }
    }];
}

#pragma mark - Convenience

- (void)setCurrentlyDisplayedViewController:(UIViewController <NYTPhotoContainer> *)viewController animated:(BOOL)animated {
    if (!viewController) {
        return;
    }
    
    if ([viewController.photo isEqual:self.currentlyDisplayedPhoto]) {
        animated = NO;
    }
    
    NSInteger currentIdx = [self.dataSource indexOfPhoto:self.currentlyDisplayedPhoto];
    NSInteger newIdx = [self.dataSource indexOfPhoto:viewController.photo];
    UIPageViewControllerNavigationDirection direction = (newIdx < currentIdx) ? UIPageViewControllerNavigationDirectionReverse : UIPageViewControllerNavigationDirectionForward;
    
    [self.pageViewController setViewControllers:@[viewController] direction:direction animated:animated completion:nil];
}

- (void)setOverlayViewHidden:(BOOL)hidden animated:(BOOL)animated {
    if (hidden == self.overlayView.hidden) {
        return;
    }
    
    if (animated) {
        self.overlayView.hidden = NO;
        
        self.overlayView.alpha = hidden ? 1.0 : 0.0;
        
        [UIView animateWithDuration:NYTPhotosViewControllerOverlayAnimationDuration delay:0.0 options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionAllowAnimatedContent | UIViewAnimationOptionAllowUserInteraction animations:^{
            self.overlayView.alpha = hidden ? 0.0 : 1.0;
        } completion:^(BOOL finished) {
            self.overlayView.alpha = 1.0;
            self.overlayView.hidden = hidden;
        }];
    }
    else {
        self.overlayView.hidden = hidden;
    }
}

- (NYTPhotoViewController *)newPhotoViewControllerForPhoto:(id <NYTPhoto>)photo {
    if (photo) {
        UIView *loadingView;
        if ([self.delegate respondsToSelector:@selector(photosViewController:loadingViewForPhoto:)]) {
            loadingView = [self.delegate photosViewController:self loadingViewForPhoto:photo];
        }
        
        NYTPhotoViewController *photoViewController = [[NYTPhotoViewController alloc] initWithPhoto:photo loadingView:loadingView notificationCenter:self.notificationCenter];
        photoViewController.delegate = self;
        [self.singleTapGestureRecognizer requireGestureRecognizerToFail:photoViewController.doubleTapGestureRecognizer];
        
        if([self.delegate respondsToSelector:@selector(photosViewController:maximumZoomScaleForPhoto:)]) {
            CGFloat maximumZoomScale = [self.delegate photosViewController:self maximumZoomScaleForPhoto:photo];
            photoViewController.scalingImageView.maximumZoomScale = maximumZoomScale;
        }
        
        // TODO: Update overlay view
        [self updateOverlayInformation];
        
        return photoViewController;
    }
    
    return nil;
}

- (void)didNavigateToPhoto:(id <NYTPhoto>)photo {
    if ([self.delegate respondsToSelector:@selector(photosViewController:didNavigateToPhoto:atIndex:)]) {
        [self.delegate photosViewController:self didNavigateToPhoto:photo atIndex:[self.dataSource indexOfPhoto:photo]];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:NYTPhotosViewControllerDidNavigateToPhotoNotification object:self];
}

- (id <NYTPhoto>)currentlyDisplayedPhoto {
    return self.currentPhotoViewController.photo;
}

- (NYTPhotoViewController *)currentPhotoViewController {
    return self.pageViewController.viewControllers.firstObject;
}

- (UIView *)referenceViewForCurrentPhoto {
    if ([self.delegate respondsToSelector:@selector(photosViewController:referenceViewForPhoto:)]) {
        return [self.delegate photosViewController:self referenceViewForPhoto:self.currentlyDisplayedPhoto];
    }
    
    return nil;
}

- (CGPoint)boundsCenterPoint {
    return CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
}

#pragma mark - NYTPhotoViewControllerDelegate

- (void)photoViewController:(NYTPhotoViewController *)photoViewController didLongPressWithGestureRecognizer:(UILongPressGestureRecognizer *)longPressGestureRecognizer {
    
    self.shouldHandleLongPress = NO;
    
    // Show share action
    [self shareActionTapped:longPressGestureRecognizer];
}

#pragma mark - UIPageViewControllerDataSource

- (UIViewController *)pageViewController:(UIPageViewController *)pageViewController viewControllerBeforeViewController:(UIViewController <NYTPhotoContainer> *)viewController {
    NSUInteger photoIndex = [self.dataSource indexOfPhoto:viewController.photo];
    if (photoIndex == 0 || photoIndex == NSNotFound) {
        return nil;
    }
    
    return [self newPhotoViewControllerForPhoto:[self.dataSource photoAtIndex:(photoIndex - 1)]];
}

- (UIViewController *)pageViewController:(UIPageViewController *)pageViewController viewControllerAfterViewController:(UIViewController <NYTPhotoContainer> *)viewController {
    NSUInteger photoIndex = [self.dataSource indexOfPhoto:viewController.photo];
    if (photoIndex == NSNotFound) {
        return nil;
    }
    
    return [self newPhotoViewControllerForPhoto:[self.dataSource photoAtIndex:(photoIndex + 1)]];
}

#pragma mark - UIPageViewControllerDelegate

- (void)pageViewController:(UIPageViewController *)pageViewController didFinishAnimating:(BOOL)finished previousViewControllers:(NSArray *)previousViewControllers transitionCompleted:(BOOL)completed {
    if (completed) {
        [self updateOverlayInformation];
        
        UIViewController <NYTPhotoContainer> *photoViewController = pageViewController.viewControllers.firstObject;
        [self didNavigateToPhoto:photoViewController.photo];
    }
}

@end
