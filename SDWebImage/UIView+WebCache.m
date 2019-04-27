/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "UIView+WebCache.h"
#import "objc/runtime.h"
#import "UIView+WebCacheOperation.h"

NSString * const SDWebImageInternalSetImageGroupKey = @"internalSetImageGroup";
NSString * const SDWebImageExternalCustomManagerKey = @"externalCustomManager";

const int64_t SDWebImageProgressUnitCountUnknown = 1LL;

static char imageURLKey;

#if SD_UIKIT
static char TAG_ACTIVITY_INDICATOR;
static char TAG_ACTIVITY_STYLE;
static char TAG_ACTIVITY_SHOW;
#endif

@implementation UIView (WebCache)

- (nullable NSURL *)sd_imageURL {
    return objc_getAssociatedObject(self, &imageURLKey);
}

- (NSProgress *)sd_imageProgress {
    NSProgress *progress = objc_getAssociatedObject(self, @selector(sd_imageProgress));
    if (!progress) {
        progress = [[NSProgress alloc] initWithParent:nil userInfo:nil];
        self.sd_imageProgress = progress;
    }
    return progress;
}

- (void)setSd_imageProgress:(NSProgress *)sd_imageProgress {
    objc_setAssociatedObject(self, @selector(sd_imageProgress), sd_imageProgress, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)sd_internalSetImageWithURL:(nullable NSURL *)url
                  placeholderImage:(nullable UIImage *)placeholder
                           options:(SDWebImageOptions)options
                      operationKey:(nullable NSString *)operationKey
                     setImageBlock:(nullable SDSetImageBlock)setImageBlock
                          progress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                         completed:(nullable SDExternalCompletionBlock)completedBlock {
    return [self sd_internalSetImageWithURL:url placeholderImage:placeholder options:options operationKey:operationKey setImageBlock:setImageBlock progress:progressBlock completed:completedBlock context:nil];
}

- (void)sd_internalSetImageWithURL:(nullable NSURL *)url
                  placeholderImage:(nullable UIImage *)placeholder
                           options:(SDWebImageOptions)options
                      operationKey:(nullable NSString *)operationKey
                     setImageBlock:(nullable SDSetImageBlock)setImageBlock
                          progress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                         completed:(nullable SDExternalCompletionBlock)completedBlock
                           context:(nullable NSDictionary<NSString *, id> *)context {
    // HUGY 11.19
    // 获取有效的OperationKey 没有的话就拿到当前的类名作为key  作用是什么呢？？？
    NSString *validOperationKey = operationKey ?: NSStringFromClass([self class]);
    NSLog(@"防止串图的秘钥  validOperationKey = %@",validOperationKey);
    // 取消该密钥对应的图片加载操作
    // SSSS------  用来防止串图
    [self sd_cancelImageLoadOperationWithKey:validOperationKey];
    //设置关联对象url
    objc_setAssociatedObject(self, &imageURLKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"用来存储 值的 context %@",context);
    //通过SDWebImageInternalSetImageGroupKey 获取GCD的 group
    dispatch_group_t group = context[SDWebImageInternalSetImageGroupKey];
    //如果 options 与 SDWebImageDelayPlaceholder 为false  如果没有选择延迟加载占位图
    if (!(options & SDWebImageDelayPlaceholder)) {
        if (group) {
            dispatch_group_enter(group);
        }
        // 在主线程主队列中设置占位图
        dispatch_main_async_safe(^{
            //设置image 为 placeholder
            [self sd_setImage:placeholder imageData:nil basedOnClassOrViaCustomSetImageBlock:setImageBlock];
        });
    }
    
    // 如果传入了图片链接
    if (url) {
#if SD_UIKIT
        // 如果设置要显示加载小菊花，就添加加载小菊花并开始动画
        if ([self sd_showActivityIndicatorView]) {
            [self sd_addActivityIndicator];
        }
#endif
        
        // reset the progress
        // 重设totalUnitCount（总大小） 跟 completedUnitCount（当前大小）
        self.sd_imageProgress.totalUnitCount = 0;
        self.sd_imageProgress.completedUnitCount = 0;
        // 生成图片管理者，如果context中有就用context中的，否则就直接生成
        SDWebImageManager *manager = [context objectForKey:SDWebImageExternalCustomManagerKey];
        //如果管理器不存在 则新建一个
        if (!manager) {
            manager = [SDWebImageManager sharedManager];
        }
        
        __weak __typeof(self)wself = self;
        // 生成一个代码块用来在下载图片的方法中监听进度并进行回调
        SDWebImageDownloaderProgressBlock combinedProgressBlock = ^(NSInteger receivedSize, NSInteger expectedSize, NSURL * _Nullable targetURL) {
            //设置totalUnitCount
            wself.sd_imageProgress.totalUnitCount = expectedSize;
            //设置receivedSize
            wself.sd_imageProgress.completedUnitCount = receivedSize;
            if (progressBlock) {
                progressBlock(receivedSize, expectedSize, targetURL);
            }
        };
        // 生成图片操作对象，并开始下载图片
        id <SDWebImageOperation> operation = [manager loadImageWithURL:url options:options progress:combinedProgressBlock completed:^(UIImage *image, NSData *data, NSError *error, SDImageCacheType cacheType, BOOL finished, NSURL *imageURL) {
            // 如果没有生成强引用的self就终止执行
            __strong __typeof (wself) sself = wself;
            if (!sself) { return; }
#if SD_UIKIT
            // 如果有加载小菊花的话就移除掉
            [sself sd_removeActivityIndicator];
#endif
            // if the progress not been updated, mark it to complete state
            // 如果已经完成并且没有错误，并且进度没有更新，就将进度状态设为未知
            if (finished && !error && sself.sd_imageProgress.totalUnitCount == 0 && sself.sd_imageProgress.completedUnitCount == 0) {
                sself.sd_imageProgress.totalUnitCount = SDWebImageProgressUnitCountUnknown;
                sself.sd_imageProgress.completedUnitCount = SDWebImageProgressUnitCountUnknown;
            }
            // 是否应该回调完成blok： 如果已经完成或者设置了在设置图片前处理
            // // 设置了SDWebImageAvoidAutoSetImage 默认不会将UIImage添加进UIImageView对象里面，而放置在conpleteBlock里面交由调用方自己处理，做个滤镜或者淡入淡出什么的

            BOOL shouldCallCompletedBlock = finished || (options & SDWebImageAvoidAutoSetImage);
            // 是否应该不设置图片： 如果有图片但设置了在设置图片前处理，或者没有图片并且没有设置延迟加载占位图
            BOOL shouldNotSetImage = ((image && (options & SDWebImageAvoidAutoSetImage)) ||
                                      (!image && !(options & SDWebImageDelayPlaceholder)));
            // 生成完成回调代码块
            SDWebImageNoParamsBlock callCompletedBlockClojure = ^{
                // 如果没有生成强引用的self就终止执行
                if (!sself) { return; }
                // 如果需要设置图片就直接刷新视图
                if (!shouldNotSetImage) {
                    [sself sd_setNeedsLayout];
                }
                // 如果传入了回调block并且应该进行回调，就直接回调
                if (completedBlock && shouldCallCompletedBlock) {
                    completedBlock(image, error, cacheType, url);
                }
            };
            
            // case 1a: we got an image, but the SDWebImageAvoidAutoSetImage flag is set
            // OR
            // case 1b: we got no image and the SDWebImageDelayPlaceholder is not set
            // 如果不需要设置图片就在主线程主队列中调用上面生成的完成回调代码块，并且不再向下执行
            if (shouldNotSetImage) {
                dispatch_main_async_safe(callCompletedBlockClojure);
                return;
            }
            // 生成变量保存数据
            UIImage *targetImage = nil;
            NSData *targetData = nil;
            if (image) {
                // 如果图片下载成功就用变量保存图片
                // case 2a: we got an image and the SDWebImageAvoidAutoSetImage is not set
                targetImage = image;
                targetData = data;
            } else if (options & SDWebImageDelayPlaceholder) {
                // 如果图片下载失败并且设置了延迟加载占位图，就保存占位图
                // case 2b: we got no image and the SDWebImageDelayPlaceholder flag is set
                targetImage = placeholder;
                targetData = nil;
            }
            
#if SD_UIKIT || SD_MAC
            // check whether we should use the image transition
            // 检查一下是否应该转换图片：如果下载完成，并且设置了图片强制转换或者图片缓存类型是不缓存直接从网络加载，就进行强制转换
            SDWebImageTransition *transition = nil;
            if (finished && (options & SDWebImageForceTransition || cacheType == SDImageCacheTypeNone)) {
                transition = sself.sd_imageTransition;
            }
#endif
            dispatch_main_async_safe(^{
                // 如果context中有调度组，就获取并进入调度组
                if (group) {
                    dispatch_group_enter(group);
                }
#if SD_UIKIT || SD_MAC
                 // 在主线程主队列中设置图片
                [sself sd_setImage:targetImage imageData:targetData basedOnClassOrViaCustomSetImageBlock:setImageBlock transition:transition cacheType:cacheType imageURL:imageURL];
#else
                [sself sd_setImage:targetImage imageData:targetData basedOnClassOrViaCustomSetImageBlock:setImageBlock];
#endif
                // 调度完成后调用完成回调代码块
                if (group) {
                    // compatible code for FLAnimatedImage, because we assume completedBlock called after image was set. This will be removed in 5.x
                    BOOL shouldUseGroup = [objc_getAssociatedObject(group, &SDWebImageInternalSetImageGroupKey) boolValue];
                    if (shouldUseGroup) {
                        dispatch_group_notify(group, dispatch_get_main_queue(), callCompletedBlockClojure);
                    } else {
                        callCompletedBlockClojure();
                    }
                } else {
                    callCompletedBlockClojure();
                }
            });
        }];
        // 根据密钥保存下载图片的操作
        //SSSS------  用来防止串图
        [self sd_setImageLoadOperation:operation forKey:validOperationKey];
    } else {
        dispatch_main_async_safe(^{
#if SD_UIKIT
            // 如果没传入图片链接，就在主线程主队列移除加载小菊花
            [self sd_removeActivityIndicator];
#endif
            // 如果传入了完成回调block就回调错误信息
            if (completedBlock) {
                NSError *error = [NSError errorWithDomain:SDWebImageErrorDomain code:-1 userInfo:@{NSLocalizedDescriptionKey : @"Trying to load a nil url"}];
                completedBlock(nil, error, SDImageCacheTypeNone, url);
            }
        });
    }
}

- (void)sd_cancelCurrentImageLoad {
    [self sd_cancelImageLoadOperationWithKey:NSStringFromClass([self class])];
}

//将图片设置到控件上的主方法
- (void)sd_setImage:(UIImage *)image imageData:(NSData *)imageData basedOnClassOrViaCustomSetImageBlock:(SDSetImageBlock)setImageBlock {
#if SD_UIKIT || SD_MAC
    [self sd_setImage:image imageData:imageData basedOnClassOrViaCustomSetImageBlock:setImageBlock transition:nil cacheType:0 imageURL:nil];
#else
    // watchOS does not support view transition. Simplify the logic
    if (setImageBlock) {
        setImageBlock(image, imageData);
    } else if ([self isKindOfClass:[UIImageView class]]) {
        UIImageView *imageView = (UIImageView *)self;
        [imageView setImage:image];
    }
#endif
}

/*
 在方法的开始，根据控件所属类的不同，生成最终设置图片的代码块。
 接下来如果设置了过度动画，就执行过度动画
 如果没设置过度动画，就直接传参调用在方法开始生成的最终设置图片的代码块。
 */

//将图片设置到控件上的主方法
#if SD_UIKIT || SD_MAC
- (void)sd_setImage:(UIImage *)image imageData:(NSData *)imageData basedOnClassOrViaCustomSetImageBlock:(SDSetImageBlock)setImageBlock transition:(SDWebImageTransition *)transition cacheType:(SDImageCacheType)cacheType imageURL:(NSURL *)imageURL {
    // 获取到当前视图
    UIView *view = self;
    // 设置临时变量保存设置图片代码块
    SDSetImageBlock finalSetImageBlock;
    // 如果设置了设置图片代码块就直接设置代码块
    if (setImageBlock) {
        finalSetImageBlock = setImageBlock;
    } else if ([view isKindOfClass:[UIImageView class]]) {
        // 如果是该类是图片视图，就创建设置图片代码块并在其中为图片视图设置图片
        UIImageView *imageView = (UIImageView *)view;
        finalSetImageBlock = ^(UIImage *setImage, NSData *setImageData) {
            imageView.image = setImage;
        };
    }
#if SD_UIKIT
    else if ([view isKindOfClass:[UIButton class]]) {
        // 如果是该类是按钮，就创建设置图片代码块并在其中为按钮在正常状态下设置图片
        UIButton *button = (UIButton *)view;
        finalSetImageBlock = ^(UIImage *setImage, NSData *setImageData){
            [button setImage:setImage forState:UIControlStateNormal];
        };
    }
#endif
    // 如果设置了过度
    if (transition) {
#if SD_UIKIT
        [UIView transitionWithView:view duration:0 options:0 animations:^{
            // 0 duration to let UIKit render placeholder and prepares block
            // 如果在展示过渡动画之前设置了要执行的代码块就先执行
            if (transition.prepares) {
                transition.prepares(view, image, imageData, cacheType, imageURL);
            }
        } completion:^(BOOL finished) {
             // 开始执行动画
            [UIView transitionWithView:view duration:transition.duration options:transition.animationOptions animations:^{
                // 如果设置了代码块并且没设置避免自动设置图片，就直接传参并调用代码块
                if (finalSetImageBlock && !transition.avoidAutoSetImage) {
                    finalSetImageBlock(image, imageData);
                }
                // 如果设置了动画代码块，就传参并调用代码块
                if (transition.animations) {
                    transition.animations(view, image);
                }
            // 如果设置了完成代码块，就传参并调用代码块
            } completion:transition.completion];
        }];
#elif SD_MAC
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull prepareContext) {
            // 0 duration to let AppKit render placeholder and prepares block
            prepareContext.duration = 0;
            if (transition.prepares) {
                transition.prepares(view, image, imageData, cacheType, imageURL);
            }
        } completionHandler:^{
            [NSAnimationContext runAnimationGroup:^(NSAnimationContext * _Nonnull context) {
                context.duration = transition.duration;
                context.timingFunction = transition.timingFunction;
                context.allowsImplicitAnimation = (transition.animationOptions & SDWebImageAnimationOptionAllowsImplicitAnimation);
                if (finalSetImageBlock && !transition.avoidAutoSetImage) {
                    finalSetImageBlock(image, imageData);
                }
                if (transition.animations) {
                    transition.animations(view, image);
                }
            } completionHandler:^{
                if (transition.completion) {
                    transition.completion(YES);
                }
            }];
        }];
#endif
    } else {
         // 如果设置了设置图片代码块就传参并调用代码块
        if (finalSetImageBlock) {
            finalSetImageBlock(image, imageData);
        }
    }
}
#endif

- (void)sd_setNeedsLayout {
#if SD_UIKIT
    [self setNeedsLayout];
#elif SD_MAC
    [self setNeedsLayout:YES];
#elif SD_WATCH
    // Do nothing because WatchKit automatically layout the view after property change
#endif
}

#if SD_UIKIT || SD_MAC

#pragma mark - Image Transition
- (SDWebImageTransition *)sd_imageTransition {
    return objc_getAssociatedObject(self, @selector(sd_imageTransition));
}

- (void)setSd_imageTransition:(SDWebImageTransition *)sd_imageTransition {
    objc_setAssociatedObject(self, @selector(sd_imageTransition), sd_imageTransition, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#if SD_UIKIT

#pragma mark - Activity indicator
- (UIActivityIndicatorView *)activityIndicator {
    return (UIActivityIndicatorView *)objc_getAssociatedObject(self, &TAG_ACTIVITY_INDICATOR);
}

- (void)setActivityIndicator:(UIActivityIndicatorView *)activityIndicator {
    objc_setAssociatedObject(self, &TAG_ACTIVITY_INDICATOR, activityIndicator, OBJC_ASSOCIATION_RETAIN);
}

- (void)sd_setShowActivityIndicatorView:(BOOL)show {
    objc_setAssociatedObject(self, &TAG_ACTIVITY_SHOW, @(show), OBJC_ASSOCIATION_RETAIN);
}

- (BOOL)sd_showActivityIndicatorView {
    return [objc_getAssociatedObject(self, &TAG_ACTIVITY_SHOW) boolValue];
}

- (void)sd_setIndicatorStyle:(UIActivityIndicatorViewStyle)style{
    objc_setAssociatedObject(self, &TAG_ACTIVITY_STYLE, [NSNumber numberWithInt:style], OBJC_ASSOCIATION_RETAIN);
}

- (int)sd_getIndicatorStyle{
    return [objc_getAssociatedObject(self, &TAG_ACTIVITY_STYLE) intValue];
}

- (void)sd_addActivityIndicator {
    dispatch_main_async_safe(^{
        if (!self.activityIndicator) {
            self.activityIndicator = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:[self sd_getIndicatorStyle]];
            self.activityIndicator.translatesAutoresizingMaskIntoConstraints = NO;
        
            [self addSubview:self.activityIndicator];
            
            [self addConstraint:[NSLayoutConstraint constraintWithItem:self.activityIndicator
                                                             attribute:NSLayoutAttributeCenterX
                                                             relatedBy:NSLayoutRelationEqual
                                                                toItem:self
                                                             attribute:NSLayoutAttributeCenterX
                                                            multiplier:1.0
                                                              constant:0.0]];
            [self addConstraint:[NSLayoutConstraint constraintWithItem:self.activityIndicator
                                                             attribute:NSLayoutAttributeCenterY
                                                             relatedBy:NSLayoutRelationEqual
                                                                toItem:self
                                                             attribute:NSLayoutAttributeCenterY
                                                            multiplier:1.0
                                                              constant:0.0]];
        }
        [self.activityIndicator startAnimating];
    });
}

- (void)sd_removeActivityIndicator {
    dispatch_main_async_safe(^{
        if (self.activityIndicator) {
            [self.activityIndicator removeFromSuperview];
            self.activityIndicator = nil;
        }
    });
}

#endif

#endif

@end
