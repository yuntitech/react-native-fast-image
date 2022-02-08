#import "FFFastImageView.h"
#import <SDWebImage/UIImage+MultiFormat.h>
#import <SDWebImage/UIView+WebCache.h>
#import <AVFoundation/AVFoundation.h>
@interface FFFastImageView()

@property (nonatomic, assign) BOOL hasSentOnLoadStart;
@property (nonatomic, assign) BOOL hasCompleted;
@property (nonatomic, assign) BOOL hasErrored;
// Whether the latest change of props requires the image to be reloaded
@property (nonatomic, assign) BOOL needsReload;

@property (nonatomic, strong) NSDictionary* onLoadEvent;

@end

@implementation FFFastImageView

- (id) init {
    self = [super init];
    self.resizeMode = RCTResizeModeCover;
    self.clipsToBounds = YES;
    return self;
}

- (void)setResizeImage:(NSDictionary *)resizeImage
{
    if (_resizeImage != resizeImage) {
        _resizeImage = resizeImage;
    }
}

- (void)setResizeMode:(RCTResizeMode)resizeMode {
    if (_resizeMode != resizeMode) {
        _resizeMode = resizeMode;
        self.contentMode = (UIViewContentMode)resizeMode;
    }
}

- (void)setOnFastImageLoadEnd:(RCTDirectEventBlock)onFastImageLoadEnd {
    _onFastImageLoadEnd = onFastImageLoadEnd;
    if (self.hasCompleted) {
        _onFastImageLoadEnd(@{});
    }
}

- (void)setOnFastImageLoad:(RCTDirectEventBlock)onFastImageLoad {
    _onFastImageLoad = onFastImageLoad;
    if (self.hasCompleted) {
        _onFastImageLoad(self.onLoadEvent);
    }
}

- (void)setOnFastImageError:(RCTDirectEventBlock)onFastImageError {
    _onFastImageError = onFastImageError;
    if (self.hasErrored) {
        _onFastImageError(@{});
    }
}

- (void)setOnFastImageLoadStart:(RCTDirectEventBlock)onFastImageLoadStart {
    if (_source && !self.hasSentOnLoadStart) {
        _onFastImageLoadStart = onFastImageLoadStart;
        onFastImageLoadStart(@{});
        self.hasSentOnLoadStart = YES;
    } else {
        _onFastImageLoadStart = onFastImageLoadStart;
        self.hasSentOnLoadStart = NO;
    }
}

- (void)setImageColor:(UIColor *)imageColor {
    if (imageColor != nil) {
        _imageColor = imageColor;
        super.image = [self makeImage:super.image withTint:self.imageColor];
    }
}

- (UIImage*)makeImage:(UIImage *)image withTint:(UIColor *)color {
    UIImage *newImage = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    UIGraphicsBeginImageContextWithOptions(image.size, NO, newImage.scale);
    [color set];
    [newImage drawInRect:CGRectMake(0, 0, image.size.width, newImage.size.height)];
    newImage = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return newImage;
}

- (void)setImage:(UIImage *)image {
    if (self.imageColor != nil) {
        super.image = [self makeImage:image withTint:self.imageColor];
    } else {
        super.image = image;
    }
}

- (void)sendOnLoad:(UIImage *)image {
    self.onLoadEvent = @{
                         @"width":[NSNumber numberWithDouble:image.size.width],
                         @"height":[NSNumber numberWithDouble:image.size.height]
                         };
    if (self.onFastImageLoad) {
        self.onFastImageLoad(self.onLoadEvent);
    }
}

- (void)setSource:(FFFastImageSource *)source {
    if (_source != source) {
        _source = source;
        _needsReload = YES;
    }
}

- (void)didSetProps:(NSArray<NSString *> *)changedProps
{
    if (_needsReload) {
        [self reloadImage];
    }
}

- (void)reloadImage
{
    _needsReload = NO;

    if (_source) {

        // Load base64 images.
        NSString* url = [_source.url absoluteString];
        if (url && [url hasPrefix:@"data:image"]) {
            if (self.onFastImageLoadStart) {
                self.onFastImageLoadStart(@{});
                self.hasSentOnLoadStart = YES;
            } {
                self.hasSentOnLoadStart = NO;
            }
            // Use SDWebImage API to support external format like WebP images
            UIImage *image = [UIImage sd_imageWithData:[NSData dataWithContentsOfURL:_source.url]];
            [self setImage:image];
            if (self.onFastImageProgress) {
                self.onFastImageProgress(@{
                                           @"loaded": @(1),
                                           @"total": @(1)
                                           });
            }
            self.hasCompleted = YES;
            [self sendOnLoad:image];
            
            if (self.onFastImageLoadEnd) {
                self.onFastImageLoadEnd(@{});
            }
            return;
        }
        
        // Set headers.
        NSDictionary *headers = _source.headers;
        SDWebImageDownloaderRequestModifier *requestModifier = [SDWebImageDownloaderRequestModifier requestModifierWithBlock:^NSURLRequest * _Nullable(NSURLRequest * _Nonnull request) {
            NSMutableURLRequest *mutableRequest = [request mutableCopy];
            for (NSString *header in headers) {
                NSString *value = headers[header];
                [mutableRequest setValue:value forHTTPHeaderField:header];
            }
            return [mutableRequest copy];
        }];
        SDWebImageContext *context = @{SDWebImageContextDownloadRequestModifier : requestModifier};
        
        // Set priority.
        SDWebImageOptions options = SDWebImageRetryFailed | SDWebImageHandleCookies;
        switch (_source.priority) {
            case FFFPriorityLow:
                options |= SDWebImageLowPriority;
                break;
            case FFFPriorityNormal:
                // Priority is normal by default.
                break;
            case FFFPriorityHigh:
                options |= SDWebImageHighPriority;
                break;
        }
        
        switch (_source.cacheControl) {
            case FFFCacheControlWeb:
                options |= SDWebImageRefreshCached;
                break;
            case FFFCacheControlCacheOnly:
                options |= SDWebImageFromCacheOnly;
                break;
            case FFFCacheControlImmutable:
                break;
        }
        
        if (self.onFastImageLoadStart) {
            self.onFastImageLoadStart(@{});
            self.hasSentOnLoadStart = YES;
        } {
            self.hasSentOnLoadStart = NO;
        }
        self.hasCompleted = NO;
        self.hasErrored = NO;
        
        [self downloadImage:_source options:options context:context];
    }
}

- (void)downloadImage:(FFFastImageSource *) source options:(SDWebImageOptions) options context:(SDWebImageContext *)context {
    __weak typeof(self) weakSelf = self; // Always use a weak reference to self in blocks
    Class animatedImageClass = [SDAnimatedImage class];
    SDWebImageMutableContext *mutableContext;
    if (context) {
        mutableContext = [context mutableCopy];
    } else {
        mutableContext = [NSMutableDictionary dictionary];
    }
    mutableContext[SDWebImageContextAnimatedImageClass] = animatedImageClass;
    
    if ([self needReizeImage]) {
        if (self.resizeImage[@"width"] == nil || self.resizeImage[@"height"] == nil) {
            RCTLog(@"resizeImage 参数为空");
        } else {
            CGFloat resizeWidth = [self.resizeImage[@"width"] floatValue];
            CGFloat resizeHeight = [self.resizeImage[@"height"] floatValue];
            CGFloat scale = [UIScreen mainScreen].scale;
            mutableContext[SDWebImageContextImageThumbnailPixelSize] = @(CGSizeMake(resizeWidth * scale, resizeHeight * scale));
        }
    }
    
    [self sd_setImageWithURL:_source.url
    placeholderImage:nil
             options:options
             context:mutableContext
            progress:^(NSInteger receivedSize, NSInteger expectedSize, NSURL * _Nullable targetURL) {
                if (weakSelf.onFastImageProgress) {
                    weakSelf.onFastImageProgress(@{
                                                   @"loaded": @(receivedSize),
                                                   @"total": @(expectedSize)
                                                   });
                }
            } completed:^(UIImage * _Nullable image,
                          NSError * _Nullable error,
                          SDImageCacheType cacheType,
                          NSURL * _Nullable imageURL) {
                if (error) {
                    weakSelf.hasErrored = YES;
                        if (weakSelf.onFastImageError) {
                            weakSelf.onFastImageError(@{});
                        }
                        if (weakSelf.onFastImageLoadEnd) {
                            weakSelf.onFastImageLoadEnd(@{});
                        }
                } else {
                    weakSelf.hasCompleted = YES;
                    [weakSelf sendOnLoad:image];
                    if (weakSelf.onFastImageLoadEnd) {
                        weakSelf.onFastImageLoadEnd(@{});
                    }
                }
            }];
}

#pragma mark - private methods
/**
 是否需要进行缩放
 */
- (BOOL)needReizeImage
{
    return self.resizeImage != nil && self.resizeImage.allKeys.count > 0 && self.resizeImage.allValues.count > 0;
}

#pragma mark - 缩放
- (UIImage *)resizeImage:(UIImage *)image imageData:(NSData *)imageData dimension:(NSDictionary *)dimension
{
    if (dimension[@"width"] == nil || dimension[@"height"] == nil) {
        RCTLog(@"resizeImage 参数为空");
        return image;
    }
    
    CGFloat cropWidth = [dimension[@"width"] floatValue];
    CGFloat cropHeight = [dimension[@"height"] floatValue];
    
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)imageData, NULL);
    if (source) {
        NSDictionary* options = @{(id)kCGImageSourceShouldAllowFloat : (id)kCFBooleanTrue,
                                    (id)kCGImageSourceCreateThumbnailWithTransform : (id)kCFBooleanFalse,
                                    (id)kCGImageSourceCreateThumbnailFromImageIfAbsent : (id)kCFBooleanTrue,
                                    (id)kCGImageSourceThumbnailMaxPixelSize : @(MAX(cropWidth, cropHeight))
                                    };
        
        CGImageRef imageRef = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
        if (imageRef) {
            UIImage *targetImage = [UIImage imageWithCGImage:imageRef];
            CGImageRelease(imageRef);
            CFRelease(source);
            return targetImage;
        } else {
            return image;
        }
    } else {
        return image;
    }
}

- (SDAnimatedImage *)resizeGifImage:(SDAnimatedImage *)image imageData:(NSData *)imageData dimension:(NSDictionary *)dimension
{
    if (dimension[@"width"] == nil || dimension[@"height"] == nil) {
        RCTLog(@"resizeImage 参数为空");
        return image;
    }
    
    CGFloat cropWidth = [dimension[@"width"] floatValue];
    CGFloat cropHeight = [dimension[@"height"] floatValue];
    
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)imageData, NULL);
    if (source) {
        // 取出动图的 帧数
        size_t count = CGImageSourceGetCount(source);
        NSMutableArray *images = [NSMutableArray array];
        NSTimeInterval duration = 0;
        for (size_t i = 0; i < count; i++) {
            CGImageRef imageRef = [self createThumbnailWithImageSource:source cropWidth:cropWidth cropHeight:cropHeight];
            if (imageRef) {
                UIImage *newImage = [UIImage imageWithCGImage:imageRef];
                [images addObject:newImage];
                duration += [self hhtk_frameDurationAtIndex:i source:source];
                CGImageRelease(imageRef);
            }
        }
        UIImage *animatedImage = [UIImage animatedImageWithImages:images duration:duration];
        CFRelease(source);
        return [SDAnimatedImage imageWithData:animatedImage.sd_imageData];
    } else {
        return image;
    }
}

- (float)hhtk_frameDurationAtIndex:(NSUInteger)index source:(CGImageSourceRef)source {
    float frameDuration = 0.1f;
    CFDictionaryRef cfFrameProperties = CGImageSourceCopyPropertiesAtIndex(source, index, nil);
    NSDictionary *frameProperties = (__bridge NSDictionary *)cfFrameProperties;
    NSDictionary *gifProperties = frameProperties[(NSString *)kCGImagePropertyGIFDictionary];
    
    NSNumber *delayTimeUnclampedProp = gifProperties[(NSString *)kCGImagePropertyGIFUnclampedDelayTime];
    if (delayTimeUnclampedProp) {
        frameDuration = [delayTimeUnclampedProp floatValue];
    } else {
        NSNumber *delayTimeProp = gifProperties[(NSString *)kCGImagePropertyGIFDelayTime];
        if (delayTimeProp) {
            frameDuration = [delayTimeProp floatValue];
        }
    }
    
    // Many annoying ads specify a 0 duration to make an image flash as quickly as possible.
    // We follow Firefox's behavior and use a duration of 100 ms for any frames that specify
    // a duration of <= 10 ms. See <rdar://problem/7689300> and <http://webkit.org/b/36082>
    // for more information.
    
    if (frameDuration < 0.011f) {
        frameDuration = 0.100f;
    }
    
    CFRelease(cfFrameProperties);
    return frameDuration;
}

- (CGImageRef)createThumbnailWithImageSource:(CGImageSourceRef)imageSource cropWidth:(CGFloat)cropWidth cropHeight:(CGFloat)cropHeight
{
    NSDictionary* options = @{(id)kCGImageSourceShouldAllowFloat : (id)kCFBooleanTrue,
                                (id)kCGImageSourceCreateThumbnailWithTransform : (id)kCFBooleanFalse,
                                (id)kCGImageSourceCreateThumbnailFromImageIfAbsent : (id)kCFBooleanTrue,
                                (id)kCGImageSourceThumbnailMaxPixelSize : @(MAX(cropWidth, cropHeight))
                                };
    CGImageRef imageRef = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, (__bridge CFDictionaryRef)options);
    return imageRef;
}

- (void)dealloc {
    [self sd_cancelCurrentImageLoad];
}

@end
