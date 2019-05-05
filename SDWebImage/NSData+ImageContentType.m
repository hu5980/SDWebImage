/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 * (c) Fabrice Aneche
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "NSData+ImageContentType.h"
#if SD_MAC
#import <CoreServices/CoreServices.h>
#else
#import <MobileCoreServices/MobileCoreServices.h>
#endif

// Currently Image/IO does not support WebP
#define kSDUTTypeWebP ((__bridge CFStringRef)@"public.webp")
// AVFileTypeHEIC/AVFileTypeHEIF is defined in AVFoundation via iOS 11, we use this without import AVFoundation
#define kSDUTTypeHEIC ((__bridge CFStringRef)@"public.heic")
#define kSDUTTypeHEIF ((__bridge CFStringRef)@"public.heif")

@implementation NSData (ImageContentType)

/**
 通过图片的二进制数据判断图片的格式
 */
+ (SDImageFormat)sd_imageFormatForImageData:(nullable NSData *)data {
    if (!data) {
        return SDImageFormatUndefined;
    }
    
    // File signatures table: http://www.garykessler.net/library/file_sigs.html
    uint8_t c;
    // 获取图片二级制数据的第一个字节，也就是八个比特
    [data getBytes:&c length:1];
    //根据第一个字节进行判断
    switch (c) {
        case 0xFF:
            return SDImageFormatJPEG;
        case 0x89:
            return SDImageFormatPNG;
        case 0x47:
            return SDImageFormatGIF;
        case 0x49:
        case 0x4D:
            return SDImageFormatTIFF;
        case 0x52: {
            // WebP格式的判断要复杂些：首先图片二级制的长度要超过12个字节，
            // 并且开头的12个字节通过ASCII编码后的字符串要以“RIFF”开头，并且以“WEBP”结束。
            if (data.length >= 12) {
                //RIFF....WEBP
                NSString *testString = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(0, 12)] encoding:NSASCIIStringEncoding];
                if ([testString hasPrefix:@"RIFF"] && [testString hasSuffix:@"WEBP"]) {
                    return SDImageFormatWebP;
                }
            }
            break;
        }
        case 0x00: {
            // HEIC格式的图片判断也比其他的要复杂些：首先图片二级制的长度也要超过12个字节，
            // 然后从第四个字节开始取八个字节并通过ASCII编码转换成字符串，
            // 如果字符串中包含“ftypheic”、“ftypheix”、“ftyphevc”和“ftyphevx”中的任意一个字符串就可以
            
            if (data.length >= 12) {
                //....ftypheic ....ftypheix ....ftyphevc ....ftyphevx
                NSString *testString = [[NSString alloc] initWithData:[data subdataWithRange:NSMakeRange(4, 8)] encoding:NSASCIIStringEncoding];
                if ([testString isEqualToString:@"ftypheic"]
                    || [testString isEqualToString:@"ftypheix"]
                    || [testString isEqualToString:@"ftyphevc"]
                    || [testString isEqualToString:@"ftyphevx"]) {
                    return SDImageFormatHEIC;
                }
                if ([testString isEqualToString:@"ftypmif1"] || [testString isEqualToString:@"ftypmsf1"]) {
                    return SDImageFormatHEIF;
                }
            }
            break;
        }
    }
    return SDImageFormatUndefined;
}
// 将指定的图片格式转换成格式标识
+ (nonnull CFStringRef)sd_UTTypeFromSDImageFormat:(SDImageFormat)format {
    CFStringRef UTType;
    switch (format) {
        case SDImageFormatJPEG:
            UTType = kUTTypeJPEG;
            break;
        case SDImageFormatPNG:
            UTType = kUTTypePNG;
            break;
        case SDImageFormatGIF:
            UTType = kUTTypeGIF;
            break;
        case SDImageFormatTIFF:
            UTType = kUTTypeTIFF;
            break;
        case SDImageFormatWebP:
            UTType = kSDUTTypeWebP;
            break;
        case SDImageFormatHEIC:
            UTType = kSDUTTypeHEIC;
            break;
        case SDImageFormatHEIF:
            UTType = kSDUTTypeHEIF;
            break;
        default:
            // default is kUTTypePNG
            UTType = kUTTypePNG;
            break;
    }
    return UTType;
}

/**
 将指定的图片格式转换成格式标识
 */
+ (SDImageFormat)sd_imageFormatFromUTType:(CFStringRef)uttype {
    if (!uttype) {
        return SDImageFormatUndefined;
    }
    SDImageFormat imageFormat;
    if (CFStringCompare(uttype, kUTTypeJPEG, 0) == kCFCompareEqualTo) {
        imageFormat = SDImageFormatJPEG;
    } else if (CFStringCompare(uttype, kUTTypePNG, 0) == kCFCompareEqualTo) {
        imageFormat = SDImageFormatPNG;
    } else if (CFStringCompare(uttype, kUTTypeGIF, 0) == kCFCompareEqualTo) {
        imageFormat = SDImageFormatGIF;
    } else if (CFStringCompare(uttype, kUTTypeTIFF, 0) == kCFCompareEqualTo) {
        imageFormat = SDImageFormatTIFF;
    } else if (CFStringCompare(uttype, kSDUTTypeWebP, 0) == kCFCompareEqualTo) {
        imageFormat = SDImageFormatWebP;
    } else if (CFStringCompare(uttype, kSDUTTypeHEIC, 0) == kCFCompareEqualTo) {
        imageFormat = SDImageFormatHEIC;
    } else if (CFStringCompare(uttype, kSDUTTypeHEIF, 0) == kCFCompareEqualTo) {
        imageFormat = SDImageFormatHEIF;
    } else {
        imageFormat = SDImageFormatUndefined;
    }
    return imageFormat;
}

@end
