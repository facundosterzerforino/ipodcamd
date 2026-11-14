/*
 * ipodcamd - headless MJPEG camera server for old iOS devices (iOS 6+, armv7)
 *
 * Streams the device cameras over HTTP:
 *   /                          live-view page with Back / Front / Both buttons (no page reloads)
 *   /stream[?cam=back|front|both]   multipart MJPEG; also /stream/back, /stream/front, /stream/both
 *   /snapshot.jpg[?cam=...]    single JPEG; also /snapshot/back.jpg, ...
 *   /status                    JSON (cameras, viewers, motion score per camera, uptime)
 *   /switch?cam=front|back     change the default camera (the one used when nobody asks for a specific one)
 *
 * Only one camera can run at a time on these devices. When viewers want different cameras the daemon
 * alternates between them; "both" is a side-by-side picture where the camera that is currently live is
 * marked with a green bar and the other tile shows its last frame (grey bar).
 *
 * Needs a jailbroken device only to install it and to run it as a LaunchDaemon; it uses no private APIs.
 * Build: see README.md. MIT licensed.
 */
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>
#include <arpa/inet.h>
#include <errno.h>
#include <libkern/OSAtomic.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#define IPODCAMD_VERSION "0.2.0"
#define MAX_CONNS 8
#define DEFAULT_CONF "/var/mobile/Library/Preferences/ipodcamd.conf"
#define BOUNDARY "ipodcamdframe"

enum { CAM_BACK = 0, CAM_FRONT = 1, CAM_BOTH = 2 };
static const char *kCamName[3] = {"back", "front", "both"};

/* ------------------------------------------------------------------ config */

typedef struct {
    int port;
    int def_cam;       /* CAM_BACK or CAM_FRONT: used when a request does not name a camera */
    int width, height; /* back camera preset; the front camera is limited to 640x480 */
    int fps;           /* max frames per second sent to each viewer */
    int quality;       /* JPEG quality 1..100 */
    int rotate[2];     /* per camera: 0, 90, 180, 270 (clockwise) */
    char user[48];
    char pass[64];
    float motion_threshold; /* percent of changed samples that counts as motion */
    double dwell;           /* seconds per camera when both are being watched */
    int stack;              /* "both" layout: 0 = side by side, 1 = one above the other */
} Config;

static Config gCfg;
static const char *gConfPath = DEFAULT_CONF;

static double now_s(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec + (double)tv.tv_usec / 1e6;
}

static void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf_(const char *fmt, ...) {
    time_t t = time(NULL);
    struct tm tmv;
    char ts[32];
    localtime_r(&t, &tmv);
    strftime(ts, sizeof ts, "%Y-%m-%d %H:%M:%S", &tmv);
    fprintf(stderr, "%s ipodcamd: ", ts);
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

static char *trim(char *s) {
    while (*s == ' ' || *s == '\t') s++;
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r' || s[n - 1] == ' ' || s[n - 1] == '\t')) s[--n] = 0;
    return s;
}

static void random_password(char *out, size_t n) {
    static const char alphabet[] = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789";
    for (size_t i = 0; i + 1 < n; i++) out[i] = alphabet[arc4random_uniform(sizeof alphabet - 1)];
    out[n - 1] = 0;
}

static int norm_rot(int r) {
    r = ((r % 360) + 360) % 360;
    return (r / 90) * 90;
}

static void save_config(const char *path) {
    mode_t old = umask(077);
    FILE *f = fopen(path, "w");
    umask(old);
    if (!f) {
        logf_("cannot write %s: %s", path, strerror(errno));
        return;
    }
    fprintf(f,
            "# ipodcamd configuration (restart the daemon after editing)\n"
            "# camera: back | front   (default camera when a request does not name one)\n"
            "# resolution: 352x288 | 640x480 | 1280x720 (back camera; the front camera is limited to 640x480)\n"
            "# rotate: 0 | 90 | 180 | 270 (clockwise, both cameras); rotate_back / rotate_front override it\n"
            "# fps: maximum frames per second sent to each viewer; quality: JPEG 1-100\n"
            "# motion_threshold: percent of the picture that must change to count as motion\n"
            "# both_dwell: seconds per camera while both are being watched; both_layout: side | stack\n"
            "port=%d\ncamera=%s\nresolution=%dx%d\nfps=%d\nquality=%d\nrotate=%d\n"
            "user=%s\npassword=%s\nmotion_threshold=%.1f\nboth_dwell=%.1f\nboth_layout=%s\n",
            gCfg.port, kCamName[gCfg.def_cam], gCfg.width, gCfg.height, gCfg.fps, gCfg.quality, gCfg.rotate[0],
            gCfg.user, gCfg.pass, gCfg.motion_threshold, gCfg.dwell, gCfg.stack ? "stack" : "side");
    fclose(f);
}

static void load_config(const char *path) {
    memset(&gCfg, 0, sizeof gCfg);
    gCfg.port = 8080;
    gCfg.width = 640;
    gCfg.height = 480;
    gCfg.fps = 10;
    gCfg.quality = 70;
    gCfg.motion_threshold = 2.0f;
    gCfg.dwell = 3.0;
    strcpy(gCfg.user, "ipodcam");
    int rot_all = 0, rot_back = -1, rot_front = -1;

    FILE *f = fopen(path, "r");
    if (f) {
        char line[256];
        while (fgets(line, sizeof line, f)) {
            char *l = trim(line);
            if (!*l || *l == '#') continue;
            char *eq = strchr(l, '=');
            if (!eq) continue;
            *eq = 0;
            char *k = trim(l), *v = trim(eq + 1);
            if (!strcmp(k, "port")) gCfg.port = atoi(v);
            else if (!strcmp(k, "camera")) gCfg.def_cam = !strcasecmp(v, "front") ? CAM_FRONT : CAM_BACK;
            else if (!strcmp(k, "resolution")) {
                int w = 0, h = 0;
                if (sscanf(v, "%dx%d", &w, &h) == 2 && w > 0 && h > 0) { gCfg.width = w; gCfg.height = h; }
            }
            else if (!strcmp(k, "fps")) gCfg.fps = atoi(v);
            else if (!strcmp(k, "quality")) gCfg.quality = atoi(v);
            else if (!strcmp(k, "rotate")) rot_all = atoi(v);
            else if (!strcmp(k, "rotate_back")) rot_back = atoi(v);
            else if (!strcmp(k, "rotate_front")) rot_front = atoi(v);
            else if (!strcmp(k, "user")) strlcpy(gCfg.user, v, sizeof gCfg.user);
            else if (!strcmp(k, "password")) strlcpy(gCfg.pass, v, sizeof gCfg.pass);
            else if (!strcmp(k, "motion_threshold")) gCfg.motion_threshold = (float)atof(v);
            else if (!strcmp(k, "both_dwell")) gCfg.dwell = atof(v);
            else if (!strcmp(k, "both_layout")) gCfg.stack = !strcasecmp(v, "stack");
        }
        fclose(f);
    }
    if (gCfg.port < 1 || gCfg.port > 65535) gCfg.port = 8080;
    if (gCfg.fps < 1) gCfg.fps = 1;
    if (gCfg.fps > 30) gCfg.fps = 30;
    if (gCfg.quality < 1) gCfg.quality = 1;
    if (gCfg.quality > 100) gCfg.quality = 100;
    if (gCfg.dwell < 1.5) gCfg.dwell = 1.5;
    if (gCfg.dwell > 60) gCfg.dwell = 60;
    gCfg.rotate[CAM_BACK] = norm_rot(rot_back >= 0 ? rot_back : rot_all);
    gCfg.rotate[CAM_FRONT] = norm_rot(rot_front >= 0 ? rot_front : rot_all);
    if (!gCfg.user[0]) strcpy(gCfg.user, "ipodcam");
    if (!gCfg.pass[0]) { /* never run a LAN camera without a password */
        random_password(gCfg.pass, 13);
        save_config(path);
        logf_("no password configured: generated one and wrote %s", path);
    }
}

/* ------------------------------------------------------------ shared state */

static NSCondition *gCond;                 /* guards gJPEG / gSeq */
static NSData *gJPEG[3];                   /* latest JPEG per view: back, front, both */
static uint64_t gSeq[3];

static NSLock *gImgLock;                   /* guards gImg / gImgSeq / gImgTime */
static CGImageRef gImg[2];                 /* latest rotated frame per camera */
static uint64_t gImgSeq[2];

static volatile int32_t gConns;            /* open HTTP connections */
static volatile int32_t gViewers[3];       /* streaming connections per view */
static volatile int32_t gSnapWanted[3];    /* snapshot requests waiting for a frame, per view */
static volatile uint64_t gFramesCaptured;
static volatile double gLastFrameTime;
static volatile double gLastDemand;
static double gStartTime;
static volatile size_t gFrameW[2], gFrameH[2];
static volatile size_t gLastJPEGBytes;
static volatile uint64_t gFramesEncoded;

static AVCaptureSession *gSession;
static AVCaptureDevice *gDevices[2];
static AVCaptureDeviceInput *gInputs[2];
static AVCaptureDeviceInput *gCurInput;
static volatile int gActive = -1;          /* camera currently delivering frames */
static volatile int gDefaultCam;           /* camera used when nobody asks for a specific one */
static volatile double gSwitchTime;        /* when the active camera last changed */
static volatile double gSettleUntil;       /* frames before this are dropped (exposure warm-up) */
static dispatch_queue_t gCapQueue;
static NSLock *gSessionLock;

/* ---------------------------------------------------------- image handling */

/* Copy a camera frame into an image that owns its pixels, applying the configured rotation. */
static CGImageRef make_image(void *base, size_t w, size_t h, size_t bpr, int rot) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    const CGBitmapInfo bi = kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst; /* BGRA */
    CGContextRef src = CGBitmapContextCreate(base, w, h, 8, bpr, cs, bi);
    if (!src) { CGColorSpaceRelease(cs); return NULL; }
    CGImageRef srcImg = CGBitmapContextCreateImage(src);
    CGContextRelease(src);
    if (!srcImg) { CGColorSpaceRelease(cs); return NULL; }

    size_t ow = (rot == 90 || rot == 270) ? h : w;
    size_t oh = (rot == 90 || rot == 270) ? w : h;
    CGContextRef dst = CGBitmapContextCreate(NULL, ow, oh, 8, 0, cs, bi); /* own memory */
    CGColorSpaceRelease(cs);
    if (!dst) { CGImageRelease(srcImg); return NULL; }
    if (rot == 90) {
        CGContextTranslateCTM(dst, 0, (CGFloat)w);
        CGContextRotateCTM(dst, -M_PI_2);
    } else if (rot == 270) {
        CGContextTranslateCTM(dst, (CGFloat)h, 0);
        CGContextRotateCTM(dst, M_PI_2);
    } else if (rot == 180) {
        CGContextTranslateCTM(dst, (CGFloat)w, (CGFloat)h);
        CGContextRotateCTM(dst, M_PI);
    }
    CGContextDrawImage(dst, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), srcImg);
    CGImageRelease(srcImg);
    CGImageRef out = CGBitmapContextCreateImage(dst);
    CGContextRelease(dst);
    return out;
}

static NSData *jpeg_from_image(CGImageRef img) {
    NSMutableData *data = [NSMutableData dataWithCapacity:64 * 1024];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, kUTTypeJPEG, 1, NULL);
    if (!dest) return nil;
    NSDictionary *opts = @{ (__bridge id)kCGImageDestinationLossyCompressionQuality : @(gCfg.quality / 100.0) };
    CGImageDestinationAddImage(dest, img, (__bridge CFDictionaryRef)opts);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return ok ? data : nil;
}

/* Side-by-side (or stacked) picture of the last frame of each camera. Green bar = live, grey = last frame. */
static NSData *composite_jpeg(void) {
    CGImageRef im[2] = {NULL, NULL};
    [gImgLock lock];
    for (int c = 0; c < 2; c++) if (gImg[c]) im[c] = CGImageRetain(gImg[c]);
    [gImgLock unlock];
    if (!im[0] && !im[1]) return nil;

    size_t tw[2], th[2];
    for (int c = 0; c < 2; c++) {
        BOOL portrait = (gCfg.rotate[c] == 90 || gCfg.rotate[c] == 270);
        tw[c] = portrait ? 480 : 640;
        th[c] = portrait ? 640 : 480;
    }
    size_t W, H, tx[2], ty[2];
    if (gCfg.stack) {
        W = tw[0] > tw[1] ? tw[0] : tw[1];
        H = th[0] + th[1];
        tx[0] = (W - tw[0]) / 2; ty[0] = th[1];
        tx[1] = (W - tw[1]) / 2; ty[1] = 0;
    } else {
        W = tw[0] + tw[1];
        H = th[0] > th[1] ? th[0] : th[1];
        tx[0] = 0;     ty[0] = (H - th[0]) / 2;
        tx[1] = tw[0]; ty[1] = (H - th[1]) / 2;
    }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, W, H, 8, 0, cs, kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst);
    CGColorSpaceRelease(cs);
    if (!ctx) { for (int c = 0; c < 2; c++) if (im[c]) CGImageRelease(im[c]); return nil; }
    CGContextSetRGBFillColor(ctx, 0.1f, 0.1f, 0.1f, 1.0f);
    CGContextFillRect(ctx, CGRectMake(0, 0, (CGFloat)W, (CGFloat)H));
    CGContextSetInterpolationQuality(ctx, kCGInterpolationLow);
    int active = gActive;
    for (int c = 0; c < 2; c++) {
        if (im[c]) {
            double iw = (double)CGImageGetWidth(im[c]), ih = (double)CGImageGetHeight(im[c]);
            double s = (double)tw[c] / iw;
            if ((double)th[c] / ih < s) s = (double)th[c] / ih;
            double dw = iw * s, dh = ih * s;
            CGContextDrawImage(ctx, CGRectMake((CGFloat)tx[c] + ((CGFloat)tw[c] - (CGFloat)dw) / 2,
                                               (CGFloat)ty[c] + ((CGFloat)th[c] - (CGFloat)dh) / 2, (CGFloat)dw, (CGFloat)dh),
                               im[c]);
            CGImageRelease(im[c]);
        }
        if (c == active) CGContextSetRGBFillColor(ctx, 0.1f, 0.8f, 0.2f, 1.0f);
        else CGContextSetRGBFillColor(ctx, 0.45f, 0.45f, 0.45f, 1.0f);
        CGContextFillRect(ctx, CGRectMake((CGFloat)tx[c], (CGFloat)(ty[c] + th[c]) - 6, (CGFloat)tw[c], 6));
    }
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!out) return nil;
    NSData *jpeg = jpeg_from_image(out);
    CGImageRelease(out);
    return jpeg;
}

static void publish(int idx, NSData *jpeg) {
    [gCond lock];
    gJPEG[idx] = jpeg;
    gSeq[idx]++;
    [gCond broadcast];
    [gCond unlock];
}

/* ------------------------------------------------------------------ motion */

#define MGX 64
#define MGY 48
static unsigned char gPrev[2][MGX * MGY];
static int gHavePrev[2];
static volatile float gMotionPct[2];
static volatile double gLastMotionTime[2];

/* Compare a 64x48 grid of block-averaged luma values (4x4 pixels each) with the previous call for the
 * same camera. Averaging suppresses sensor noise; the mean brightness change is subtracted so that
 * auto-exposure shifts and flicker do not count as motion. */
static void update_motion(int c, const unsigned char *base, size_t w, size_t h, size_t bpr) {
    unsigned char cur[MGX * MGY];
    for (int gy = 0; gy < MGY; gy++) {
        size_t y0 = (size_t)gy * h / MGY;
        for (int gx = 0; gx < MGX; gx++) {
            size_t x0 = (size_t)gx * w / MGX;
            unsigned sum = 0;
            for (size_t dy = 0; dy < 4; dy++) {
                const unsigned char *row = base + (y0 + dy) * bpr + x0 * 4; /* B G R X */
                for (size_t dx = 0; dx < 4; dx++) {
                    const unsigned char *p = row + dx * 4;
                    sum += (unsigned)((p[0] * 29 + p[1] * 150 + p[2] * 77) >> 8);
                }
            }
            cur[gy * MGX + gx] = (unsigned char)(sum / 16);
        }
    }
    if (gHavePrev[c]) {
        long shift = 0;
        for (int i = 0; i < MGX * MGY; i++) shift += (int)cur[i] - (int)gPrev[c][i];
        shift /= (MGX * MGY);
        int changed = 0;
        for (int i = 0; i < MGX * MGY; i++) {
            int d = (int)cur[i] - (int)gPrev[c][i] - (int)shift;
            if (d < 0) d = -d;
            if (d > 18) changed++;
        }
        float pct = 100.0f * (float)changed / (float)(MGX * MGY);
        gMotionPct[c] = pct;
        if (pct >= gCfg.motion_threshold) gLastMotionTime[c] = now_s();
    }
    memcpy(gPrev[c], cur, sizeof cur);
    gHavePrev[c] = 1;
}

/* ----------------------------------------------------------------- capture */

static int camera_of(AVCaptureConnection *conn) {
    for (AVCaptureInputPort *p in conn.inputPorts) {
        AVCaptureInput *in = p.input;
        if (in == (AVCaptureInput *)gInputs[CAM_FRONT]) return CAM_FRONT;
        if (in == (AVCaptureInput *)gInputs[CAM_BACK]) return CAM_BACK;
    }
    return gActive;
}

@interface CamDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

@implementation CamDelegate {
    double _lastImg[2];
    double _lastMotion[2];
}
- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sb
           fromConnection:(AVCaptureConnection *)connection {
    double t = now_s();
    gLastFrameTime = t;
    gFramesCaptured++;
    if (t < gSettleUntil) return; /* exposure still settling after a camera switch */
    int c = camera_of(connection);
    if (c < 0 || c > 1) return;

    BOOL snap = gSnapWanted[c] > 0 || gSnapWanted[CAM_BOTH] > 0;
    BOOL wantAny = snap || gViewers[c] > 0 || gViewers[CAM_BOTH] > 0;
    BOOL wantImage = wantAny && (snap || (t - _lastImg[c]) >= 1.0 / (double)gCfg.fps - 0.012);
    BOOL wantMotion = (t - _lastMotion[c]) >= 0.25;
    if (!wantImage && !wantMotion) return;

    CVImageBufferRef ib = CMSampleBufferGetImageBuffer(sb);
    if (!ib) return;
    CVPixelBufferLockBaseAddress(ib, 0);
    unsigned char *base = (unsigned char *)CVPixelBufferGetBaseAddress(ib);
    size_t w = CVPixelBufferGetWidth(ib), h = CVPixelBufferGetHeight(ib), bpr = CVPixelBufferGetBytesPerRow(ib);
    gFrameW[c] = w;
    gFrameH[c] = h;
    if (base) {
        if (wantMotion) {
            _lastMotion[c] = t;
            update_motion(c, base, w, h, bpr);
        }
        if (wantImage) {
            _lastImg[c] = t;
            CGImageRef img = make_image(base, w, h, bpr, gCfg.rotate[c]);
            if (img) {
                [gImgLock lock];
                if (gImg[c]) CGImageRelease(gImg[c]);
                gImg[c] = img; /* ownership moves to gImg */
                gImgSeq[c]++;
                [gImgLock unlock];
                if (gViewers[c] > 0 || gSnapWanted[c] > 0) {
                    NSData *jpeg;
                    [gImgLock lock]; CGImageRef tmp = gImg[c] ? CGImageRetain(gImg[c]) : NULL; [gImgLock unlock];
                    jpeg = tmp ? jpeg_from_image(tmp) : nil;
                    if (tmp) CGImageRelease(tmp);
                    if (jpeg) {
                        gFramesEncoded++;
                        gLastJPEGBytes = [jpeg length];
                        publish(c, jpeg);
                    }
                }
                if (gViewers[CAM_BOTH] > 0) {
                    NSData *cj = composite_jpeg();
                    if (cj) publish(CAM_BOTH, cj);
                }
            }
        }
    }
    CVPixelBufferUnlockBaseAddress(ib, 0);
}
@end

static CamDelegate *gDelegate;

static NSString *preset_for(int w, int h) {
    if (w >= 1280 && h >= 720) return AVCaptureSessionPreset1280x720;
    if (w <= 352 && h <= 288) return AVCaptureSessionPreset352x288;
    return AVCaptureSessionPreset640x480;
}

/* Make camera c the live one. Caller holds gSessionLock. */
static BOOL set_input_locked(int c) {
    if (!gSession || c < 0 || c > 1 || !gInputs[c]) return NO;
    if (gActive == c && gCurInput == gInputs[c]) return YES;
    [gSession beginConfiguration];
    if (gCurInput) [gSession removeInput:gCurInput];
    BOOL ok = NO;
    if ([gSession canAddInput:gInputs[c]]) {
        [gSession addInput:gInputs[c]];
        gCurInput = gInputs[c];
        ok = YES;
    } else if (gCurInput && [gSession canAddInput:gCurInput]) {
        [gSession addInput:gCurInput]; /* put the old one back */
    }
    if (ok) {
        NSString *want = preset_for(gCfg.width, gCfg.height);
        if ([gSession canSetSessionPreset:want]) gSession.sessionPreset = want;
        else if ([gSession canSetSessionPreset:AVCaptureSessionPreset640x480]) gSession.sessionPreset = AVCaptureSessionPreset640x480;
        else gSession.sessionPreset = AVCaptureSessionPreset352x288;
    }
    [gSession commitConfiguration];
    if (!ok) return NO;
    AVCaptureDevice *dev = gDevices[c];
    if (dev && [dev lockForConfiguration:NULL]) {
        if ([dev isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus])
            dev.focusMode = AVCaptureFocusModeContinuousAutoFocus;
        if ([dev isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure])
            dev.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
        [dev unlockForConfiguration];
    }
    gHavePrev[c] = 0;
    gActive = c;
    gSwitchTime = now_s();
    gSettleUntil = gSwitchTime + 0.6;
    gLastFrameTime = gSwitchTime;
    return YES;
}

static BOOL activate_camera(int c) {
    [gSessionLock lock];
    BOOL ok = set_input_locked(c);
    [gSessionLock unlock];
    return ok;
}

static BOOL start_session(void) {
    gSession = [[AVCaptureSession alloc] init];
    for (AVCaptureDevice *d in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
        int c = (d.position == AVCaptureDevicePositionFront) ? CAM_FRONT : CAM_BACK;
        if (gDevices[c]) continue;
        NSError *err = nil;
        AVCaptureDeviceInput *in = [AVCaptureDeviceInput deviceInputWithDevice:d error:&err];
        if (!in) {
            logf_("cannot open %s camera: %s", kCamName[c], err ? [[err localizedDescription] UTF8String] : "unknown");
            continue;
        }
        gDevices[c] = d;
        gInputs[c] = in;
    }
    int first = gInputs[gDefaultCam] ? gDefaultCam : (gInputs[1 - gDefaultCam] ? 1 - gDefaultCam : -1);
    if (first < 0) {
        logf_("no usable camera found");
        return NO;
    }
    gDefaultCam = first;
    AVCaptureVideoDataOutput *out = [[AVCaptureVideoDataOutput alloc] init];
    out.alwaysDiscardsLateVideoFrames = YES;
    out.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
    [out setSampleBufferDelegate:gDelegate queue:gCapQueue];
    if (![gSession canAddOutput:out]) {
        logf_("cannot add video output");
        return NO;
    }
    [gSession addOutput:out];
    gActive = -1;
    if (!activate_camera(first)) {
        logf_("cannot start %s camera", kCamName[first]);
        return NO;
    }
    [gSession startRunning];
    logf_("camera session started: %s camera live, back %s, front %s, preset %s", kCamName[first],
          gInputs[CAM_BACK] ? "present" : "missing", gInputs[CAM_FRONT] ? "present" : "missing",
          [gSession.sessionPreset UTF8String]);
    return YES;
}

/* Decides which camera should be live: follows viewers; alternates when both cameras are wanted. */
static void *scheduler_thread(void *unused) {
    for (;;) {
        usleep(100000);
        int d0 = gViewers[CAM_BACK] + gViewers[CAM_BOTH] + gSnapWanted[CAM_BACK] + gSnapWanted[CAM_BOTH];
        int d1 = gViewers[CAM_FRONT] + gViewers[CAM_BOTH] + gSnapWanted[CAM_FRONT] + gSnapWanted[CAM_BOTH];
        double t = now_s();
        if (d0 || d1) gLastDemand = t;
        if (!gInputs[CAM_BACK]) d0 = 0;
        if (!gInputs[CAM_FRONT]) d1 = 0;
        int cur = gActive, target = cur;
        if (d0 && d1) {
            /* A viewer on the other camera gets a full dwell; a mere snapshot request only needs a moment. */
            int other = 1 - cur;
            int other_viewers = gViewers[other] + gViewers[CAM_BOTH];
            double min_live = other_viewers ? gCfg.dwell : 1.0;
            if (t - gSwitchTime >= min_live) target = other;
        } else if (d0) {
            target = CAM_BACK;
        } else if (d1) {
            target = CAM_FRONT;
        } else if (t - gLastDemand > 15.0 && cur != gDefaultCam) {
            target = gDefaultCam; /* nobody is looking: go back to the default camera so motion detection watches it */
        }
        if (target != cur && target >= 0) activate_camera(target);
    }
    return NULL;
}

/* ------------------------------------------------------------------- HTTP */

static int send_all(int fd, const void *buf, size_t len) {
    const char *p = (const char *)buf;
    while (len > 0) {
        ssize_t n = send(fd, p, len, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (n == 0) return -1;
        p += n;
        len -= (size_t)n;
    }
    return 0;
}

static void send_text(int fd, int code, const char *status, const char *ctype, const char *body, const char *extra) {
    char head[512];
    int bl = (int)strlen(body);
    int hl = snprintf(head, sizeof head,
                      "HTTP/1.0 %d %s\r\nServer: ipodcamd/" IPODCAMD_VERSION "\r\nContent-Type: %s\r\n"
                      "Content-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n%s\r\n",
                      code, status, ctype, bl, extra ? extra : "");
    send_all(fd, head, (size_t)hl);
    send_all(fd, body, (size_t)bl);
}

static int b64val(int c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

static int b64decode(const char *in, char *out, size_t outcap) {
    size_t o = 0;
    int acc = 0, bits = 0;
    for (; *in && *in != '='; in++) {
        int v = b64val((unsigned char)*in);
        if (v < 0) continue;
        acc = ((acc << 6) | v) & 0xffff;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (o + 1 >= outcap) return -1;
            out[o++] = (char)((acc >> bits) & 0xff);
        }
    }
    out[o] = 0;
    return (int)o;
}

static int ct_equal(const char *a, const char *b) {
    size_t la = strlen(a), lb = strlen(b);
    unsigned char r = (unsigned char)(la ^ lb);
    for (size_t i = 0; i < la; i++) r |= (unsigned char)(a[i] ^ b[lb ? i % lb : 0]);
    return r == 0;
}

static int check_auth(const char *req) {
    const char *p = req;
    while ((p = strchr(p, '\n')) != NULL) {
        p++;
        if (strncasecmp(p, "authorization:", 14) == 0) {
            p += 14;
            while (*p == ' ') p++;
            if (strncasecmp(p, "basic ", 6) != 0) return 0;
            p += 6;
            while (*p == ' ') p++;
            char b64[256], dec[200];
            size_t n = 0;
            while (p[n] && p[n] != '\r' && p[n] != '\n' && n < sizeof b64 - 1) { b64[n] = p[n]; n++; }
            b64[n] = 0;
            if (b64decode(b64, dec, sizeof dec) < 0) return 0;
            char *colon = strchr(dec, ':');
            if (!colon) return 0;
            *colon = 0;
            int ok_user = ct_equal(dec, gCfg.user);
            int ok_pass = ct_equal(colon + 1, gCfg.pass);
            return ok_user && ok_pass;
        }
    }
    return 0;
}

/* Which view does a request ask for? Looks at the path ("/stream/front") and the query ("?cam=front"). */
static int view_from(const char *path, const char *query) {
    const char *src[2] = {path, query};
    for (int i = 0; i < 2; i++) {
        if (!src[i]) continue;
        if (strstr(src[i], "both")) return CAM_BOTH;
        if (strstr(src[i], "front")) return CAM_FRONT;
        if (strstr(src[i], "back")) return CAM_BACK;
    }
    return gDefaultCam;
}

static NSData *fresh_jpeg(int idx, double max_wait) {
    OSAtomicIncrement32(&gSnapWanted[idx]);
    double deadline = now_s() + max_wait;
    NSData *out = nil;
    if (idx == CAM_BOTH) {
        [gImgLock lock];
        uint64_t s0 = gImgSeq[0], s1 = gImgSeq[1];
        [gImgLock unlock];
        for (;;) {
            [gImgLock lock];
            BOOL ok = (!gInputs[0] || gImgSeq[0] > s0) && (!gInputs[1] || gImgSeq[1] > s1);
            [gImgLock unlock];
            if (ok) { out = composite_jpeg(); break; }
            if (now_s() > deadline) break;
            usleep(50000);
        }
    } else {
        [gCond lock];
        uint64_t seq0 = gSeq[idx];
        while (gSeq[idx] == seq0 && now_s() < deadline)
            [gCond waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        if (gSeq[idx] != seq0) out = gJPEG[idx];
        [gCond unlock];
    }
    OSAtomicDecrement32(&gSnapWanted[idx]);
    return out;
}

static void handle_stream(int fd, int idx) {
    const char *head =
        "HTTP/1.0 200 OK\r\nServer: ipodcamd/" IPODCAMD_VERSION "\r\nCache-Control: no-cache, no-store, private\r\n"
        "Pragma: no-cache\r\nConnection: close\r\n"
        "Content-Type: multipart/x-mixed-replace; boundary=" BOUNDARY "\r\n\r\n";
    if (send_all(fd, head, strlen(head)) < 0) return;
    OSAtomicIncrement32(&gViewers[idx]);
    uint64_t last = 0;
    for (;;) {
        NSData *frame = nil;
        [gCond lock];
        double deadline = now_s() + 5.0;
        while (gSeq[idx] == last && now_s() < deadline)
            [gCond waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        if (gSeq[idx] != last) { frame = gJPEG[idx]; last = gSeq[idx]; }
        [gCond unlock];
        if (!frame) {
            /* camera not live right now (or stalled): keep the connection alive */
            if (send_all(fd, "--" BOUNDARY "\r\n\r\n", strlen("--" BOUNDARY "\r\n\r\n")) < 0) break;
            continue;
        }
        char ph[160];
        int pl = snprintf(ph, sizeof ph, "--" BOUNDARY "\r\nContent-Type: image/jpeg\r\nContent-Length: %lu\r\n\r\n",
                          (unsigned long)[frame length]);
        if (send_all(fd, ph, (size_t)pl) < 0) break;
        if (send_all(fd, [frame bytes], [frame length]) < 0) break;
        if (send_all(fd, "\r\n", 2) < 0) break;
    }
    OSAtomicDecrement32(&gViewers[idx]);
}

static const char *INDEX_HTML =
    "<!doctype html><html><head><meta charset=utf-8>"
    "<meta name=viewport content='width=device-width,initial-scale=1'><title>ipodcamd</title><style>"
    "body{font-family:sans-serif;margin:0;background:#111;color:#ddd;text-align:center}"
    "#bar{padding:.6em}button{font-size:1em;margin:0 .25em;padding:.4em .9em;border:1px solid #567;"
    "border-radius:4px;background:#222;color:#ddd}button.on{background:#2a6;color:#fff;border-color:#2a6}"
    ".info{font-size:.8em;color:#9ab;padding:.3em}img{max-width:100%;height:auto}a{color:#8cf}"
    "</style></head><body><div id=bar>"
    "<button id=b-back>Back</button><button id=b-front>Front</button><button id=b-both>Both</button>"
    " <button id=snap>Snapshot</button></div><div class=info><span id=st>&nbsp;</span> <a href=/status>status</a></div>"
    "<img id=v alt=stream>"
    "<script>"
    "var cur=null,img=document.getElementById('v');"
    "function show(c){cur=c;img.src='/stream?cam='+c+'&_='+new Date().getTime();"
    "var n=['back','front','both'];for(var i=0;i<3;i++){document.getElementById('b-'+n[i]).className=(n[i]==c)?'on':'';}}"
    "function snap(){window.open('/snapshot.jpg?cam='+cur,'_blank');}"
    "function poll(){var x=new XMLHttpRequest();x.open('GET','/status',true);"
    "x.onreadystatechange=function(){if(x.readyState==4&&x.status==200){try{var s=JSON.parse(x.responseText);"
    "if(cur===null){show(s.default_camera);}"
    "document.getElementById('st').textContent='live: '+s.camera+' | '+s.width+'x'+s.height"
    "+' | motion '+s.motion_pct.toFixed(1)+'% | viewers '+(s.viewers.back+s.viewers.front+s.viewers.both);"
    "}catch(e){}}};x.send();}"
    "document.getElementById('b-back').onclick=function(){show('back');};"
    "document.getElementById('b-front').onclick=function(){show('front');};"
    "document.getElementById('b-both').onclick=function(){show('both');};"
    "document.getElementById('snap').onclick=snap;poll();setInterval(poll,2000);"
    "</script></body></html>";

static void handle_status(int fd) {
    double t = now_s();
    int act = gActive < 0 ? gDefaultCam : gActive;
    double since[2];
    for (int c = 0; c < 2; c++) since[c] = gLastMotionTime[c] > 0 ? t - gLastMotionTime[c] : -1.0;
    char body[1400];
    snprintf(body, sizeof body,
             "{\"version\":\"" IPODCAMD_VERSION "\",\"camera\":\"%s\",\"default_camera\":\"%s\","
             "\"width\":%lu,\"height\":%lu,\"fps_limit\":%d,\"quality\":%d,"
             "\"viewers\":{\"back\":%d,\"front\":%d,\"both\":%d},"
             "\"frames_captured\":%llu,\"frames_encoded\":%llu,\"last_jpeg_bytes\":%lu,\"seconds_since_frame\":%.2f,"
             "\"motion_pct\":%.2f,\"motion_threshold\":%.2f,\"seconds_since_motion\":%.1f,"
             "\"cameras\":{\"back\":{\"present\":%s,\"rotate\":%d,\"motion_pct\":%.2f,\"seconds_since_motion\":%.1f},"
             "\"front\":{\"present\":%s,\"rotate\":%d,\"motion_pct\":%.2f,\"seconds_since_motion\":%.1f}},"
             "\"uptime_s\":%.0f}\n",
             kCamName[act], kCamName[gDefaultCam], (unsigned long)gFrameW[act], (unsigned long)gFrameH[act], gCfg.fps,
             gCfg.quality, (int)gViewers[0], (int)gViewers[1], (int)gViewers[2], (unsigned long long)gFramesCaptured,
             (unsigned long long)gFramesEncoded, (unsigned long)gLastJPEGBytes, t - gLastFrameTime, (double)gMotionPct[act],
             (double)gCfg.motion_threshold, since[act], gInputs[0] ? "true" : "false", gCfg.rotate[0], (double)gMotionPct[0],
             since[0], gInputs[1] ? "true" : "false", gCfg.rotate[1], (double)gMotionPct[1], since[1], t - gStartTime);
    send_text(fd, 200, "OK", "application/json", body, NULL);
}

static void *client_thread(void *arg) {
    int fd = (int)(intptr_t)arg;
    char req[4096];
    size_t got = 0;
    while (got < sizeof req - 1) {
        ssize_t n = recv(fd, req + got, sizeof req - 1 - got, 0);
        if (n <= 0) goto done;
        got += (size_t)n;
        req[got] = 0;
        if (strstr(req, "\r\n\r\n") || strstr(req, "\n\n")) break;
    }
    req[got] = 0;

    char method[8] = {0}, path[512] = {0};
    if (sscanf(req, "%7s %511s", method, path) != 2 || (strcmp(method, "GET") && strcmp(method, "HEAD"))) {
        send_text(fd, 405, "Method Not Allowed", "text/plain", "GET only\n", NULL);
        goto done;
    }
    if (!check_auth(req)) {
        usleep(700000); /* slow down password guessing */
        send_text(fd, 401, "Unauthorized", "text/plain", "authentication required\n",
                  "WWW-Authenticate: Basic realm=\"ipodcamd\"\r\n");
        goto done;
    }

    char *q = strchr(path, '?');
    if (q) *q++ = 0;

    @autoreleasepool {
        if (!strcmp(path, "/") || !strcmp(path, "/index.html")) {
            send_text(fd, 200, "OK", "text/html; charset=utf-8", INDEX_HTML, NULL);
        } else if (!strncmp(path, "/stream", 7) || !strcmp(path, "/video")) {
            int idx = view_from(path + (path[1] == 's' ? 7 : 6), q);
            if (!strcmp(method, "HEAD")) send_text(fd, 200, "OK", "multipart/x-mixed-replace", "", NULL);
            else handle_stream(fd, idx);
        } else if (!strncmp(path, "/snap", 5)) {
            int idx = view_from(path + 5, q);
            NSData *d = fresh_jpeg(idx, idx == CAM_BOTH ? 9.0 : 5.0);
            if (!d) {
                send_text(fd, 503, "Service Unavailable", "text/plain", "no frame available\n", NULL);
            } else {
                char head[256];
                int hl = snprintf(head, sizeof head,
                                  "HTTP/1.0 200 OK\r\nServer: ipodcamd/" IPODCAMD_VERSION "\r\nContent-Type: image/jpeg\r\n"
                                  "Content-Length: %lu\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n",
                                  (unsigned long)[d length]);
                send_all(fd, head, (size_t)hl);
                if (strcmp(method, "HEAD")) send_all(fd, [d bytes], [d length]);
            }
        } else if (!strcmp(path, "/status") || !strcmp(path, "/status.json")) {
            handle_status(fd);
        } else if (!strcmp(path, "/switch")) {
            int c = gDefaultCam;
            if (q && strstr(q, "cam=front")) c = CAM_FRONT;
            else if (q && strstr(q, "cam=back")) c = CAM_BACK;
            else c = 1 - c;
            if (!gInputs[c]) {
                send_text(fd, 409, "Conflict", "text/plain", "that camera is not available\n", NULL);
            } else {
                gDefaultCam = c; /* the scheduler moves to it when nobody is watching another camera */
                send_text(fd, 200, "OK", "text/plain", "default camera changed\n", NULL);
            }
        } else {
            send_text(fd, 404, "Not Found", "text/plain", "not found\n", NULL);
        }
    }
done:
    close(fd);
    OSAtomicDecrement32(&gConns);
    return NULL;
}

static void *accept_thread(void *unused) {
    int ls = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_ANY);
    a.sin_port = htons((uint16_t)gCfg.port);
    if (bind(ls, (struct sockaddr *)&a, sizeof a) < 0 || listen(ls, 16) < 0) {
        logf_("cannot listen on port %d: %s", gCfg.port, strerror(errno));
        _exit(1);
    }
    logf_("listening on port %d", gCfg.port);
    for (;;) {
        int cs = accept(ls, NULL, NULL);
        if (cs < 0) {
            if (errno != EINTR) usleep(100000);
            continue;
        }
        if (gConns >= MAX_CONNS) {
            send_text(cs, 503, "Busy", "text/plain", "too many connections\n", NULL);
            close(cs);
            continue;
        }
        OSAtomicIncrement32(&gConns);
        int on = 1;
        setsockopt(cs, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
        setsockopt(cs, IPPROTO_TCP, TCP_NODELAY, &on, sizeof on);
        struct timeval rt = {5, 0}, st = {10, 0};
        setsockopt(cs, SOL_SOCKET, SO_RCVTIMEO, &rt, sizeof rt);
        setsockopt(cs, SOL_SOCKET, SO_SNDTIMEO, &st, sizeof st);
        pthread_t th;
        pthread_attr_t at;
        pthread_attr_init(&at);
        pthread_attr_setdetachstate(&at, PTHREAD_CREATE_DETACHED);
        if (pthread_create(&th, &at, client_thread, (void *)(intptr_t)cs) != 0) {
            close(cs);
            OSAtomicDecrement32(&gConns);
        }
        pthread_attr_destroy(&at);
    }
    return NULL;
}

/* If the camera stops delivering frames (e.g. another app took it), exit and let launchd restart us. */
static void *watchdog_thread(void *unused) {
    for (;;) {
        sleep(5);
        if (now_s() - gLastFrameTime > 20.0) {
            logf_("no camera frames for 20 s: exiting so launchd restarts the daemon");
            _exit(3);
        }
    }
    return NULL;
}

static void on_term(int sig) { _exit(0); }

int main(int argc, char **argv) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        signal(SIGTERM, on_term);
        if (argc > 1) gConfPath = argv[1];
        load_config(gConfPath);
        gDefaultCam = gCfg.def_cam;
        gStartTime = now_s();
        gCond = [[NSCondition alloc] init];
        gImgLock = [[NSLock alloc] init];
        gSessionLock = [[NSLock alloc] init];
        gCapQueue = dispatch_queue_create("ipodcamd.capture", NULL);
        gDelegate = [[CamDelegate alloc] init];
        logf_("ipodcamd " IPODCAMD_VERSION " starting (user '%s', port %d)", gCfg.user, gCfg.port);
        if (!start_session()) {
            logf_("camera start failed");
            return 1;
        }
        pthread_t t1, t2, t3;
        pthread_create(&t1, NULL, accept_thread, NULL);
        pthread_create(&t2, NULL, watchdog_thread, NULL);
        pthread_create(&t3, NULL, scheduler_thread, NULL);
    }
    [[NSRunLoop currentRunLoop] run];
    return 0;
}
