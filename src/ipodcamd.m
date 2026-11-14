/*
 * ipodcamd - headless MJPEG camera server for old iOS devices (iOS 6+, armv7)
 *
 * Streams the device camera over HTTP:
 *   /                 small live-view page
 *   /stream           multipart MJPEG (works in browsers, VLC, ffplay, ffmpeg, Home Assistant, ...)
 *   /snapshot.jpg     single JPEG
 *   /status           JSON (camera, resolution, viewers, motion score, uptime)
 *   /switch?cam=front|back   change camera at runtime
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

#define IPODCAMD_VERSION "0.1.0"
#define MAX_CONNS 8
#define DEFAULT_CONF "/var/mobile/Library/Preferences/ipodcamd.conf"
#define BOUNDARY "ipodcamdframe"

/* ------------------------------------------------------------------ config */

typedef struct {
    int port;
    int front;     /* 0 = back camera, 1 = front camera */
    int width, height;
    int fps;       /* max frames per second sent to viewers */
    int quality;   /* JPEG quality 1..100 */
    int rotate;    /* 0, 90, 180, 270 (clockwise) */
    char user[48];
    char pass[64];
    float motion_threshold; /* percent of changed samples that counts as motion */
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
            "# camera: back | front\n"
            "# resolution: 352x288 | 640x480 | 1280x720 (front camera: max 640x480)\n"
            "# rotate: 0 | 90 | 180 | 270 (clockwise, applied to every frame)\n"
            "# fps: maximum frames per second sent to viewers; quality: JPEG 1-100\n"
            "# motion_threshold: percent of the picture that must change to count as motion\n"
            "port=%d\ncamera=%s\nresolution=%dx%d\nfps=%d\nquality=%d\nrotate=%d\n"
            "user=%s\npassword=%s\nmotion_threshold=%.1f\n",
            gCfg.port, gCfg.front ? "front" : "back", gCfg.width, gCfg.height, gCfg.fps, gCfg.quality,
            gCfg.rotate, gCfg.user, gCfg.pass, gCfg.motion_threshold);
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
    strcpy(gCfg.user, "ipodcam");

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
            else if (!strcmp(k, "camera")) gCfg.front = !strcasecmp(v, "front");
            else if (!strcmp(k, "resolution")) {
                int w = 0, h = 0;
                if (sscanf(v, "%dx%d", &w, &h) == 2 && w > 0 && h > 0) { gCfg.width = w; gCfg.height = h; }
            }
            else if (!strcmp(k, "fps")) gCfg.fps = atoi(v);
            else if (!strcmp(k, "quality")) gCfg.quality = atoi(v);
            else if (!strcmp(k, "rotate")) gCfg.rotate = atoi(v);
            else if (!strcmp(k, "user")) strlcpy(gCfg.user, v, sizeof gCfg.user);
            else if (!strcmp(k, "password")) strlcpy(gCfg.pass, v, sizeof gCfg.pass);
            else if (!strcmp(k, "motion_threshold")) gCfg.motion_threshold = (float)atof(v);
        }
        fclose(f);
    }
    if (gCfg.port < 1 || gCfg.port > 65535) gCfg.port = 8080;
    if (gCfg.fps < 1) gCfg.fps = 1;
    if (gCfg.fps > 30) gCfg.fps = 30;
    if (gCfg.quality < 1) gCfg.quality = 1;
    if (gCfg.quality > 100) gCfg.quality = 100;
    gCfg.rotate = ((gCfg.rotate % 360) + 360) % 360;
    gCfg.rotate = (gCfg.rotate / 90) * 90;
    if (!gCfg.user[0]) strcpy(gCfg.user, "ipodcam");
    if (!gCfg.pass[0]) { /* never run a LAN camera without a password */
        random_password(gCfg.pass, 13);
        save_config(path);
        logf_("no password configured: generated one and wrote %s", path);
    }
}

/* ------------------------------------------------------------ shared state */

static NSCondition *gCond;            /* guards gJPEG / gSeq */
static NSData *gJPEG;
static uint64_t gSeq;
static double gJPEGTime;

static volatile int32_t gConns;        /* open HTTP connections */
static volatile int32_t gViewers;      /* connections currently streaming */
static volatile int32_t gSnapWanted;   /* a snapshot request needs a fresh frame */
static volatile uint64_t gFramesCaptured, gFramesEncoded;
static volatile double gLastFrameTime;
static volatile float gMotionPct;
static volatile double gLastMotionTime;
static double gStartTime;
static volatile size_t gFrameW, gFrameH;
static volatile int gActiveFront;
static volatile size_t gLastJPEGBytes;

static AVCaptureSession *gSession;
static dispatch_queue_t gCapQueue;
static NSLock *gSessionLock;

/* ---------------------------------------------------------- image encoding */

static NSData *encode_jpeg(void *base, size_t w, size_t h, size_t bpr) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    const CGBitmapInfo bi = kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst; /* BGRA */
    CGContextRef src = CGBitmapContextCreate(base, w, h, 8, bpr, cs, bi);
    if (!src) { CGColorSpaceRelease(cs); return nil; }
    CGImageRef img = CGBitmapContextCreateImage(src);
    CGContextRelease(src);

    int rot = gCfg.rotate;
    if (img && rot != 0) {
        size_t ow = (rot == 90 || rot == 270) ? h : w;
        size_t oh = (rot == 90 || rot == 270) ? w : h;
        CGContextRef dst = CGBitmapContextCreate(NULL, ow, oh, 8, 0, cs, bi);
        if (dst) {
            if (rot == 90) {
                CGContextTranslateCTM(dst, 0, (CGFloat)w);
                CGContextRotateCTM(dst, -M_PI_2);
            } else if (rot == 270) {
                CGContextTranslateCTM(dst, (CGFloat)h, 0);
                CGContextRotateCTM(dst, M_PI_2);
            } else {
                CGContextTranslateCTM(dst, (CGFloat)w, (CGFloat)h);
                CGContextRotateCTM(dst, M_PI);
            }
            CGContextDrawImage(dst, CGRectMake(0, 0, (CGFloat)w, (CGFloat)h), img);
            CGImageRef rotated = CGBitmapContextCreateImage(dst);
            CGContextRelease(dst);
            if (rotated) { CGImageRelease(img); img = rotated; }
        }
    }
    CGColorSpaceRelease(cs);
    if (!img) return nil;

    NSMutableData *data = [NSMutableData dataWithCapacity:64 * 1024];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data, kUTTypeJPEG, 1, NULL);
    if (dest) {
        NSDictionary *opts = @{ (__bridge id)kCGImageDestinationLossyCompressionQuality : @(gCfg.quality / 100.0) };
        CGImageDestinationAddImage(dest, img, (__bridge CFDictionaryRef)opts);
        if (!CGImageDestinationFinalize(dest)) data = nil;
        CFRelease(dest);
    } else {
        data = nil;
    }
    CGImageRelease(img);
    return data;
}

/* ------------------------------------------------------------------ motion */

#define MGX 64
#define MGY 48
static unsigned char gPrev[MGX * MGY];
static int gHavePrev;

/* Compare a 64x48 grid of block-averaged luma values (4x4 pixels each) with the previous call.
 * Averaging suppresses sensor noise; the mean brightness change is subtracted so that
 * auto-exposure shifts and flicker do not count as motion. */
static void update_motion(const unsigned char *base, size_t w, size_t h, size_t bpr) {
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
    if (gHavePrev) {
        long shift = 0;
        for (int i = 0; i < MGX * MGY; i++) shift += (int)cur[i] - (int)gPrev[i];
        shift /= (MGX * MGY);
        int changed = 0;
        for (int i = 0; i < MGX * MGY; i++) {
            int d = (int)cur[i] - (int)gPrev[i] - (int)shift;
            if (d < 0) d = -d;
            if (d > 18) changed++;
        }
        float pct = 100.0f * (float)changed / (float)(MGX * MGY);
        gMotionPct = pct;
        if (pct >= gCfg.motion_threshold) gLastMotionTime = now_s();
    }
    memcpy(gPrev, cur, sizeof cur);
    gHavePrev = 1;
}

/* ----------------------------------------------------------------- capture */

@interface CamDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@end

@implementation CamDelegate {
    double _lastEncode, _lastMotionCheck;
}
- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sb
           fromConnection:(AVCaptureConnection *)connection {
    double t = now_s();
    gLastFrameTime = t;
    gFramesCaptured++;
    BOOL wantEncode = (gSnapWanted > 0) || (gViewers > 0 && (t - _lastEncode) >= 1.0 / (double)gCfg.fps - 0.012);
    BOOL wantMotion = (t - _lastMotionCheck) >= 0.25;
    if (!wantEncode && !wantMotion) return;

    CVImageBufferRef ib = CMSampleBufferGetImageBuffer(sb);
    if (!ib) return;
    CVPixelBufferLockBaseAddress(ib, 0);
    unsigned char *base = (unsigned char *)CVPixelBufferGetBaseAddress(ib);
    size_t w = CVPixelBufferGetWidth(ib), h = CVPixelBufferGetHeight(ib), bpr = CVPixelBufferGetBytesPerRow(ib);
    gFrameW = w;
    gFrameH = h;
    if (base) {
        if (wantMotion) {
            _lastMotionCheck = t;
            update_motion(base, w, h, bpr);
        }
        if (wantEncode) {
            _lastEncode = t;
            NSData *jpeg = encode_jpeg(base, w, h, bpr);
            if (jpeg) {
                gFramesEncoded++;
                gLastJPEGBytes = [jpeg length];
                [gCond lock];
                gJPEG = jpeg;
                gJPEGTime = t;
                gSeq++;
                [gCond broadcast];
                [gCond unlock];
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

static BOOL start_session(int front) {
    [gSessionLock lock];
    BOOL ok = NO;
    if (gSession) {
        [gSession stopRunning];
        gSession = nil;
    }
    AVCaptureDevicePosition want = front ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
    AVCaptureDevice *dev = nil;
    for (AVCaptureDevice *d in [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
        if (d.position == want) { dev = d; break; }
    }
    if (!dev) {
        dev = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        front = (dev.position == AVCaptureDevicePositionFront);
    }
    if (dev) {
        NSError *err = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
        AVCaptureSession *s = [[AVCaptureSession alloc] init];
        NSString *preset = preset_for(gCfg.width, gCfg.height);
        s.sessionPreset = [s canSetSessionPreset:preset] ? preset : AVCaptureSessionPreset640x480;
        if (input && [s canAddInput:input]) {
            [s addInput:input];
            AVCaptureVideoDataOutput *out = [[AVCaptureVideoDataOutput alloc] init];
            out.alwaysDiscardsLateVideoFrames = YES;
            out.videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA) };
            [out setSampleBufferDelegate:gDelegate queue:gCapQueue];
            if ([s canAddOutput:out]) {
                [s addOutput:out];
                if ([dev lockForConfiguration:NULL]) {
                    if ([dev isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus])
                        dev.focusMode = AVCaptureFocusModeContinuousAutoFocus;
                    if ([dev isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure])
                        dev.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
                    [dev unlockForConfiguration];
                }
                gSession = s;
                gActiveFront = front;
                gHavePrev = 0;
                gLastFrameTime = now_s();
                [s startRunning];
                ok = YES;
                logf_("camera session started: %s camera, preset %s", front ? "front" : "back", [s.sessionPreset UTF8String]);
            }
        } else {
            logf_("cannot open camera input: %s", err ? [[err localizedDescription] UTF8String] : "unknown");
        }
    } else {
        logf_("no video capture device found");
    }
    [gSessionLock unlock];
    return ok;
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

static NSData *fresh_jpeg(double max_wait) {
    OSAtomicIncrement32(&gSnapWanted);
    double deadline = now_s() + max_wait;
    NSData *d = nil;
    [gCond lock];
    uint64_t seq0 = gSeq;
    while (gSeq == seq0 && now_s() < deadline)
        [gCond waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    BOOL fresh = (gSeq != seq0);
    d = gJPEG;
    [gCond unlock];
    OSAtomicDecrement32(&gSnapWanted);
    return fresh ? d : nil;
}

static void handle_stream(int fd) {
    const char *head =
        "HTTP/1.0 200 OK\r\nServer: ipodcamd/" IPODCAMD_VERSION "\r\nCache-Control: no-cache, no-store, private\r\n"
        "Pragma: no-cache\r\nConnection: close\r\n"
        "Content-Type: multipart/x-mixed-replace; boundary=" BOUNDARY "\r\n\r\n";
    if (send_all(fd, head, strlen(head)) < 0) return;
    OSAtomicIncrement32(&gViewers);
    uint64_t last = 0;
    for (;;) {
        NSData *frame = nil;
        [gCond lock];
        double deadline = now_s() + 5.0;
        while (gSeq == last && now_s() < deadline)
            [gCond waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        if (gSeq != last) { frame = gJPEG; last = gSeq; }
        [gCond unlock];
        if (!frame) {
            /* camera stalled: keep the connection alive with an empty part boundary */
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
    OSAtomicDecrement32(&gViewers);
}

static const char *INDEX_HTML =
    "<!doctype html><html><head><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
    "<title>ipodcamd</title><style>body{font-family:sans-serif;margin:0;background:#111;color:#ddd;text-align:center}"
    "img{max-width:100%;height:auto}a{color:#8cf;margin:0 .6em}</style></head><body>"
    "<p><a href=/snapshot.jpg>snapshot</a><a href=/status>status</a><a href='/switch?cam=front'>front</a>"
    "<a href='/switch?cam=back'>back</a></p><img src=/stream alt=stream></body></html>";

static void handle_status(int fd) {
    double t = now_s();
    double since_motion = gLastMotionTime > 0 ? t - gLastMotionTime : -1.0;
    char body[768];
    snprintf(body, sizeof body,
             "{\"version\":\"" IPODCAMD_VERSION "\",\"camera\":\"%s\",\"width\":%lu,\"height\":%lu,"
             "\"rotate\":%d,\"fps_limit\":%d,\"quality\":%d,\"viewers\":%d,\"frames_captured\":%llu,"
             "\"frames_encoded\":%llu,\"last_jpeg_bytes\":%lu,\"seconds_since_frame\":%.2f,"
             "\"motion_pct\":%.2f,\"motion_threshold\":%.2f,\"seconds_since_motion\":%.1f,\"uptime_s\":%.0f}\n",
             gActiveFront ? "front" : "back", (unsigned long)gFrameW, (unsigned long)gFrameH, gCfg.rotate, gCfg.fps,
             gCfg.quality, (int)gViewers, (unsigned long long)gFramesCaptured, (unsigned long long)gFramesEncoded,
             (unsigned long)gLastJPEGBytes, t - gLastFrameTime, (double)gMotionPct, (double)gCfg.motion_threshold,
             since_motion, t - gStartTime);
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
        } else if (!strcmp(path, "/stream") || !strcmp(path, "/stream.mjpg") || !strcmp(path, "/video")) {
            if (!strcmp(method, "HEAD")) send_text(fd, 200, "OK", "multipart/x-mixed-replace", "", NULL);
            else handle_stream(fd);
        } else if (!strcmp(path, "/snapshot.jpg") || !strcmp(path, "/snapshot") || !strcmp(path, "/snap.jpg")) {
            NSData *d = fresh_jpeg(3.0);
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
            int front = gActiveFront;
            if (q && strstr(q, "cam=front")) front = 1;
            else if (q && strstr(q, "cam=back")) front = 0;
            else front = !front;
            BOOL ok = start_session(front);
            send_text(fd, ok ? 200 : 500, ok ? "OK" : "Error", "text/plain", ok ? "switched\n" : "switch failed\n", NULL);
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
        gStartTime = now_s();
        gCond = [[NSCondition alloc] init];
        gSessionLock = [[NSLock alloc] init];
        gCapQueue = dispatch_queue_create("ipodcamd.capture", NULL);
        gDelegate = [[CamDelegate alloc] init];
        logf_("ipodcamd " IPODCAMD_VERSION " starting (user '%s', port %d)", gCfg.user, gCfg.port);
        if (!start_session(gCfg.front)) {
            logf_("camera start failed");
            return 1;
        }
        pthread_t t1, t2;
        pthread_create(&t1, NULL, accept_thread, NULL);
        pthread_create(&t2, NULL, watchdog_thread, NULL);
    }
    [[NSRunLoop currentRunLoop] run];
    return 0;
}
