/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import <Foundation/Foundation.h>
#import "SDWebImageCompat.h"
#import "NSData+ImageContentType.h"

/**
 A Boolean value indicating whether to scale down large images during decompressing. (NSNumber)
 */
/**
 定义了一个BOOL类型的key，用于定义是否在解压缩期间缩放图片
 */
FOUNDATION_EXPORT NSString * _Nonnull const SDWebImageCoderScaleDownLargeImagesKey;

/**
 Return the shared device-dependent RGB color space created with CGColorSpaceCreateDeviceRGB.

 @return The device-dependent RGB color space
 */
/**
 定义了一个单利方法，获取设备的RGB色彩空间
 */
CG_EXTERN CGColorSpaceRef _Nonnull SDCGColorSpaceGetDeviceRGB(void);

/**
 Check whether CGImageRef contains alpha channel.

 @param imageRef The CGImageRef
 @return Return YES if CGImageRef contains alpha channel, otherwise return NO
 */
/**
 检查图片是否有透明度
 */
CG_EXTERN BOOL SDCGImageRefContainsAlpha(_Nullable CGImageRef imageRef);


/**
 This is the image coder protocol to provide custom image decoding/encoding.
 These methods are all required to implement.
 @note Pay attention that these methods are not called from main queue.
 */
@protocol SDWebImageCoder <NSObject>

@required
#pragma mark - Decoding
/**
 Returns YES if this coder can decode some data. Otherwise, the data should be passed to another coder.
 
 @param data The image data so we can look at it
 @return YES if this coder can decode the data, NO otherwise
 */
/**
 如果实现了该方法的类能解码图片数据就返回YES；否则，就返回NO
 */
- (BOOL)canDecodeFromData:(nullable NSData *)data;

/**
 Decode the image data to image.

 @param data The image data to be decoded
 @return The decoded image from data
 */
/**
 将图片数据解码为图片对象
 */
- (nullable UIImage *)decodedImageWithData:(nullable NSData *)data;

/**
 Decompress the image with original image and image data.

 @param image The original image to be decompressed
 @param data The pointer to original image data. The pointer itself is nonnull but image data can be null. This data will set to cache if needed. If you do not need to modify data at the sametime, ignore this param.
 @param optionsDict A dictionary containing any decompressing options. Pass {SDWebImageCoderScaleDownLargeImagesKey: @(YES)} to scale down large images
 @return The decompressed image
 */
/**
 用原始图像和图像数据解压缩图像
 其中参数optionsDict就是利用第一节定义的变量SDWebImageCoderScaleDownLargeImagesKey，如果value传YES就缩放图像
 */
- (nullable UIImage *)decompressedImageWithImage:(nullable UIImage *)image
                                            data:(NSData * _Nullable * _Nonnull)data
                                         options:(nullable NSDictionary<NSString*, NSObject*>*)optionsDict;

#pragma mark - Encoding

/**
 Returns YES if this coder can encode some image. Otherwise, it should be passed to another coder.
 
 @param format The image format
 @return YES if this coder can encode the image, NO otherwise
 */
- (BOOL)canEncodeToFormat:(SDImageFormat)format;

/**
 Encode the image to image data.

 @param image The image to be encoded
 @param format The image format to encode, you should note `SDImageFormatUndefined` format is also  possible
 @return The encoded image data
 */
- (nullable NSData *)encodedDataWithImage:(nullable UIImage *)image format:(SDImageFormat)format;

@end


/**
 This is the image coder protocol to provide custom progressive image decoding.
 These methods are all required to implement.
 @note Pay attention that these methods are not called from main queue.
 */
@protocol SDWebImageProgressiveCoder <SDWebImageCoder>

@required
/**
 Returns YES if this coder can incremental decode some data. Otherwise, it should be passed to another coder.
 
 @param data The image data so we can look at it
 @return YES if this coder can decode the data, NO otherwise
 */
/**
 如果实现了该方法的类能逐行解码图片数据就返回YES；否则，就返回NO
 */
- (BOOL)canIncrementallyDecodeFromData:(nullable NSData *)data;

/**
 Incremental decode the image data to image.
 
 @param data The image data has been downloaded so far
 @param finished Whether the download has finished
 @warning because incremental decoding need to keep the decoded context, we will alloc a new instance with the same class for each download operation to avoid conflicts
 @return The decoded image from data
 */
/**
 逐行解码图片数据为图像对象
 */
- (nullable UIImage *)incrementallyDecodedImageWithData:(nullable NSData *)data finished:(BOOL)finished;

@end
