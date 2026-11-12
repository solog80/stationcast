#import "StationSip.h"

#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <pjsua-lib/pjsua.h>
#import <pjmedia-codec/opus.h>

// Declared before the PJSIP C callbacks so sip_on_call_media_state can call it.
@interface StationSip (DuckingForward)
- (void)beginDuckingOnSlot:(pjsua_conf_port_id)slot;
@end

static StationSip *gSip = nil;
static char gLogPathBuf[1024] = {0};
// Android uses STREAM_MUSIC at a raised media volume; give iOS speaker
// playback equivalent headroom before the ducking attenuation is applied.
static const float kSipRxGain = 1.5f;

static void sip_file_log(NSString *msg) {
    if (gLogPathBuf[0] == 0) return;
    FILE *f = fopen(gLogPathBuf, "a");
    if (f == NULL) return;
    fprintf(f, "%s\n", msg.UTF8String);
    fclose(f);
}

#pragma mark - PJSIP callbacks

static void sip_on_reg_state2(pjsua_acc_id acc_id, pjsua_reg_info *info) {
    if (gSip == nil || info == NULL) return;
    int code = info->cbparam ? info->cbparam->code : 0;
    NSString *reason = @"";
    if (info->cbparam && info->cbparam->reason.ptr && info->cbparam->reason.slen > 0) {
        reason = [[NSString alloc] initWithBytes:info->cbparam->reason.ptr
                                          length:info->cbparam->reason.slen
                                        encoding:NSUTF8StringEncoding] ?: @"";
    }
    NSLog(@"[StationSip] on_reg_state2 code=%d reason=%@ renew=%d", code, reason, info->renew);
    NSString *state = nil;
    NSString *msg = nil;
    if (code >= 200 && code < 300) {
        state = @"registered";
    } else if (code >= 300) {
        state = @"failed";
        msg = [NSString stringWithFormat:@"SIP %d %@", code, reason];
    }
    if (state != nil) {
        __weak StationSip *weakSip = gSip;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSip.delegate sipEvent:state peer:nil message:msg];
        });
    }
}

static void sip_on_incoming_call(pjsua_acc_id acc_id, pjsua_call_id call_id, pjsip_rx_data *rdata) {
    if (gSip == nil) return;
    pjsua_call_info ci;
    NSString *peer = nil;
    if (pjsua_call_get_info(call_id, &ci) == PJ_SUCCESS) {
        peer = [NSString stringWithUTF8String:ci.remote_info.ptr];
    }
    __weak StationSip *weakSip = gSip;
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSip.delegate sipEvent:@"ringing" peer:peer message:nil];
    });
}

static void sip_on_call_state(pjsua_call_id call_id, pjsip_event *e) {
    if (gSip == nil) return;
    pjsua_call_info ci;
    if (pjsua_call_get_info(call_id, &ci) != PJ_SUCCESS) return;
    NSString *peer = [NSString stringWithUTF8String:ci.remote_info.ptr];
    NSString *state = nil;
    switch (ci.state) {
        case PJSIP_INV_STATE_CALLING:      state = @"connecting"; break;
        case PJSIP_INV_STATE_INCOMING:     state = @"ringing"; break;
        case PJSIP_INV_STATE_EARLY:        state = @"connecting"; break;
        case PJSIP_INV_STATE_CONNECTING:   state = @"connecting"; break;
        case PJSIP_INV_STATE_CONFIRMED:    state = @"live"; break;
        case PJSIP_INV_STATE_DISCONNECTED: state = @"ended"; break;
        default: break;
    }
    if (state == nil) return;
    __weak StationSip *weakSip = gSip;
    BOOL disconnected = (ci.state == PJSIP_INV_STATE_DISCONNECTED);
    dispatch_async(dispatch_get_main_queue(), ^{
        [weakSip.delegate sipEvent:state peer:peer message:nil];
        if (disconnected && weakSip != nil) {
            [weakSip performSelector:@selector(handleCallDisconnected)];
        }
    });
}

static void sip_on_call_media_state(pjsua_call_id call_id) {
    if (gSip == nil) return;
    pjsua_call_info ci;
    if (pjsua_call_get_info(call_id, &ci) != PJ_SUCCESS) return;
    pjsua_conf_port_id audioSlot = PJSUA_INVALID_ID;
    for (unsigned i = 0; i < ci.media_cnt; i++) {
        if (ci.media[i].type == PJMEDIA_TYPE_AUDIO &&
            ci.media[i].status == PJSUA_CALL_MEDIA_ACTIVE) {
            pjsua_conf_port_id slot = ci.media[i].stream.aud.conf_slot;
            if (slot != PJSUA_INVALID_ID) {
                pjsua_conf_connect(slot, 0);
                pjsua_conf_connect(0, slot);
                audioSlot = slot;
            }
        }
    }
    __weak StationSip *weakSip = gSip;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (audioSlot != PJSUA_INVALID_ID) {
            [weakSip beginDuckingOnSlot:audioSlot];
        }
        [weakSip performSelector:@selector(forceSpeaker)];
        [weakSip performSelector:@selector(startStats)];
    });
}

#pragma mark - Helpers

static double level_to_dbfs(unsigned level) {
    if (level == 0) return -60.0;
    double norm = (double)level / 255.0;
    double db = 20.0 * log10(norm);
    if (db < -60.0) db = -60.0;
    if (db > 0.0) db = 0.0;
    return db;
}

@interface StationSip ()
@property (nonatomic, assign) pjsua_acc_id accId;
@property (nonatomic, assign) pjsua_call_id callId;
@property (nonatomic, strong) NSTimer *fastTimer;
@property (nonatomic, strong) NSTimer *slowTimer;
@property (nonatomic, assign) double txLevel;
@property (nonatomic, assign) double rxLevel;
@property (nonatomic, assign) pjsua_conf_port_id callSlot;
@property (nonatomic, assign) float duckLevel;
@property (nonatomic, assign) float lastAppliedDuckLevel;
@property (nonatomic, assign) NSTimeInterval lastMicActiveAt;
@property (nonatomic, assign) BOOL engineUp;
@property (nonatomic, assign) BOOL mainThreadRegistered;
@property (nonatomic, copy) NSString *codecPref;
- (void)forceSpeaker;
- (void)clearSpeakerOverride;
- (void)updateDuckingForMicLevel:(double)micDb;
@end

@implementation StationSip

- (instancetype)init {
    self = [super init];
    if (self) {
        _accId = PJSUA_INVALID_ID;
        _callId = PJSUA_INVALID_ID;
        _engineUp = NO;
        _txLevel = -60.0;
        _rxLevel = -60.0;
        _callSlot = PJSUA_INVALID_ID;
        _duckLevel = 1.0f;
        _lastAppliedDuckLevel = -1.0f;
        _lastMicActiveAt = 0.0;
        _codecPref = @"OPUS";
    }
    return self;
}

- (void)configureAudioSession {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayAndRecord
             withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker |
                         AVAudioSessionCategoryOptionAllowBluetooth |
                         AVAudioSessionCategoryOptionAllowBluetoothA2DP
                   error:nil];
    // Use Default mode instead of VoiceChat so iOS does not apply narrow
    // telephony voice-call EQ and aggressive noise suppression to the mic.
    [session setMode:AVAudioSessionModeDefault error:nil];
    [session setPreferredSampleRate:48000.0 error:nil];
    [session setPreferredIOBufferDuration:0.02 error:nil];
    [session setActive:YES error:nil];
}

/// Route playback through the loudspeaker only when no headset/external output
/// is attached, while keeping fullband broadcast mic mode (AVAudioSessionModeDefault).
- (void)forceSpeaker {
    dispatch_async(dispatch_get_main_queue(), ^{
        AVAudioSession *session = [AVAudioSession sharedInstance];
        [session setCategory:AVAudioSessionCategoryPlayAndRecord
                 withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker |
                             AVAudioSessionCategoryOptionAllowBluetooth |
                             AVAudioSessionCategoryOptionAllowBluetoothA2DP
                       error:nil];
        [session setMode:AVAudioSessionModeDefault error:nil];
        [session setPreferredSampleRate:48000.0 error:nil];
        [session setPreferredIOBufferDuration:0.02 error:nil];
        [session setActive:YES error:nil];
        // Match the Android speaker path: always prefer the built-in speaker
        // while a SIP call is active, even if a headset is connected.
        [session overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:nil];
        [UIDevice currentDevice].proximityMonitoringEnabled = NO;
    });
}

- (void)clearSpeakerOverride {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[AVAudioSession sharedInstance]
            overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:nil];
    });
}

static pj_thread_desc gMainThreadDesc;

- (void)registerMainThread {
    if (self.mainThreadRegistered) return;
    pj_thread_t *thread = NULL;
    if (pj_thread_register("StationSipMain", gMainThreadDesc, &thread) == PJ_SUCCESS) {
        self.mainThreadRegistered = YES;
    }
}

- (void)initializeEngine {
    if (self.engineUp) return;
    gSip = self;
    [self configureAudioSession];
    [self registerMainThread];

    pj_status_t status = pjsua_create();
    if (status != PJ_SUCCESS) {
        [self.delegate sipEvent:@"failed" peer:nil message:@"pjsua_create failed"];
        return;
    }

    pjsua_config cfg;
    pjsua_config_default(&cfg);
    cfg.cb.on_reg_state2 = &sip_on_reg_state2;
    cfg.cb.on_incoming_call = &sip_on_incoming_call;
    cfg.cb.on_call_state = &sip_on_call_state;
    cfg.cb.on_call_media_state = &sip_on_call_media_state;
    cfg.max_calls = 2;
    cfg.user_agent = pj_str("StationCast-Radio");

    NSString *logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"station_sip.log"];
    strncpy(gLogPathBuf, logPath.UTF8String, sizeof(gLogPathBuf) - 1);
    sip_file_log([NSString stringWithFormat:@"=== StationSip init %@ ===", [NSDate date]]);

    pjsua_logging_config logCfg;
    pjsua_logging_config_default(&logCfg);
    logCfg.msg_logging = PJ_TRUE;
    logCfg.level = 5;
    logCfg.console_level = 0;
    logCfg.log_filename = pj_str(gLogPathBuf);
    logCfg.log_file_flags = PJ_O_APPEND;

    pjsua_media_config medCfg;
    pjsua_media_config_default(&medCfg);
    medCfg.clock_rate = 48000;
    medCfg.snd_clock_rate = 48000;
    medCfg.quality = 10;
    medCfg.ec_tail_len = 0;
    medCfg.no_vad = PJ_TRUE;
    // Absorb mobile jitter instead of letting PLC make the audio robotic.
    medCfg.jb_init = 200;
    medCfg.jb_min_pre = 100;
    medCfg.jb_max_pre = 400;
    medCfg.jb_max = 500;

    status = pjsua_init(&cfg, &logCfg, &medCfg);
    if (status != PJ_SUCCESS) {
        [self.delegate sipEvent:@"failed" peer:nil message:@"pjsua_init failed"];
        return;
    }

    pjmedia_codec_opus_config opusCfg;
    pjmedia_codec_param opusParam;
    pj_bzero(&opusParam, sizeof(opusParam));
    if (pjmedia_codec_opus_get_config(&opusCfg) == PJ_SUCCESS) {
        opusCfg.sample_rate = 48000;
        opusCfg.channel_cnt = 1;
        opusCfg.frm_ptime = 20;
        opusCfg.frm_ptime_denum = 1;
        opusCfg.bit_rate = 128000;
        opusCfg.packet_loss = 5;
        opusCfg.complexity = 10;
        opusCfg.cbr = PJ_TRUE;
        pjmedia_codec_opus_set_default_param(&opusCfg, &opusParam);
    }

    pjsua_transport_config tcfg;
    pjsua_transport_config_default(&tcfg);
    tcfg.port = 0;
    pjsua_transport_id tid;
    status = pjsua_transport_create(PJSIP_TRANSPORT_UDP, &tcfg, &tid);
    if (status != PJ_SUCCESS) {
        [self.delegate sipEvent:@"failed" peer:nil message:@"UDP transport failed"];
        return;
    }

    status = pjsua_start();
    if (status != PJ_SUCCESS) {
        [self.delegate sipEvent:@"failed" peer:nil message:@"pjsua_start failed"];
        return;
    }
    self.engineUp = YES;
    NSLog(@"[StationSip] PJSIP %s started", pj_get_version());
}

- (void)applyCodecPriorities {
    NSString *pref = self.codecPref ?: @"OPUS";
    NSArray<NSString *> *wanted;
    if ([pref isEqualToString:@"G.722"]) {
        wanted = @[@"G722/16000/1", @"G722/16000", @"opus/48000/2", @"opus/48000",
                   @"PCMA/8000/1", @"PCMU/8000/1"];
    } else if ([pref isEqualToString:@"G.711"]) {
        wanted = @[@"PCMU/8000/1", @"PCMU/8000", @"PCMA/8000/1", @"PCMA/8000",
                   @"opus/48000/2", @"G722/16000/1"];
    } else {
        wanted = @[@"opus/48000/2", @"opus/48000", @"G722/16000/1", @"G722/16000",
                   @"PCMA/8000/1", @"PCMU/8000/1"];
    }
    // Disable everything first.
    pjsua_codec_info codecs[64];
    unsigned count = 64;
    if (pjsua_enum_codecs(codecs, &count) == PJ_SUCCESS) {
        for (unsigned i = 0; i < count; i++) {
            pjsua_codec_set_priority(&codecs[i].codec_id, 0);
        }
    }
    unsigned char prio = 254;
    for (NSString *cid in wanted) {
        pj_str_t s = pj_str((char *)cid.UTF8String);
        pjsua_codec_set_priority(&s, prio);
        if (prio > 1) prio--;
    }
    pj_str_t dtmf = pj_str("telephone-event/8000");
    pjsua_codec_set_priority(&dtmf, 200);
}

- (void)registerWithHost:(NSString *)host
                    port:(int)port
                username:(NSString *)username
                password:(NSString *)password
               extension:(NSString *)extension
                   codec:(NSString *)codec {
    self.codecPref = codec.length ? codec : @"OPUS";
    [self.delegate sipEvent:@"registering" peer:nil message:nil];
    if (!self.engineUp) {
        [self initializeEngine];
        if (!self.engineUp) return;
    }
    [self registerMainThread];
    [self applyCodecPriorities];

    // Tear down any previous account first.
    if (self.accId != PJSUA_INVALID_ID) {
        pjsua_acc_set_registration(self.accId, PJ_FALSE);
        pjsua_acc_del(self.accId);
        self.accId = PJSUA_INVALID_ID;
    }

    NSString *ext = extension.length ? extension : username;
    NSString *hostPort = [host rangeOfString:@":"].location != NSNotFound
        ? host
        : [NSString stringWithFormat:@"%@:%d", host, port];
    NSString *idUri = [NSString stringWithFormat:@"\"StationCast Field\" <sip:%@@%@>", ext, hostPort];
    NSString *regUri = [NSString stringWithFormat:@"sip:%@", hostPort];
    NSString *proxyUri = [NSString stringWithFormat:@"sip:%@;lr", hostPort];

    pjsua_acc_config accCfg;
    pjsua_acc_config_default(&accCfg);
    accCfg.id = pj_str((char *)idUri.UTF8String);
    accCfg.reg_uri = pj_str((char *)regUri.UTF8String);
    accCfg.reg_timeout = 3600;
    accCfg.reg_retry_interval = 30;
    accCfg.cred_count = 1;
    accCfg.cred_info[0].realm = pj_str("*");
    accCfg.cred_info[0].scheme = pj_str("digest");
    accCfg.cred_info[0].username = pj_str((char *)ext.UTF8String);
    accCfg.cred_info[0].data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
    accCfg.cred_info[0].data = pj_str((char *)password.UTF8String);
    accCfg.proxy_cnt = 1;
    accCfg.proxy[0] = pj_str((char *)proxyUri.UTF8String);

    sip_file_log([NSString stringWithFormat:@"REGISTER ext=%@ user=%@ host=%@ passLen=%lu id=%@ reg=%@ proxy=%@",
                  ext, username, hostPort, (unsigned long)password.length, idUri, regUri, proxyUri]);
    pjsua_acc_id accId;
    pj_status_t st = pjsua_acc_add(&accCfg, PJ_TRUE, &accId);
    if (st != PJ_SUCCESS) {
        [self.delegate sipEvent:@"failed" peer:nil
                        message:[NSString stringWithFormat:@"acc_add failed (%d)", st]];
        return;
    }
    self.accId = accId;
    NSLog(@"[StationSip] registering %@@%@", ext, hostPort);
}

- (void)acceptCall {
    if (self.callId == PJSUA_INVALID_ID) return;
    pjsua_call_setting opt;
    pjsua_call_setting_default(&opt);
    opt.aud_cnt = 1;
    opt.vid_cnt = 0;
    pjsua_call_answer2(self.callId, &opt, 200, NULL, NULL);
    [self.delegate sipEvent:@"connecting" peer:nil message:nil];
}

- (void)declineCall {
    if (self.callId == PJSUA_INVALID_ID) return;
    pjsua_call_answer(self.callId, 603, NULL, NULL);
    pjsua_call_hangup(self.callId, 603, NULL, NULL);
    self.callId = PJSUA_INVALID_ID;
    [self.delegate sipEvent:@"registered" peer:nil message:nil];
}

- (void)hangupCall {
    if (self.callId == PJSUA_INVALID_ID) return;
    pjsua_call_hangup(self.callId, 0, NULL, NULL);
    self.callId = PJSUA_INVALID_ID;
    [self stopStats];
    [self.delegate sipEvent:@"ended" peer:nil message:nil];
    [self.delegate sipEvent:@"registered" peer:nil message:nil];
}

- (void)dialTarget:(NSString *)target {
    if (self.accId == PJSUA_INVALID_ID) return;
    NSString *t = [target stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (t.length == 0) return;
    NSString *uri = [t.lowercaseString hasPrefix:@"sip:"] ? t : [NSString stringWithFormat:@"sip:%@", t];

    pjsua_call_setting opt;
    pjsua_call_setting_default(&opt);
    opt.aud_cnt = 1;
    opt.vid_cnt = 0;

    pj_str_t dst = pj_str((char *)uri.UTF8String);
    pjsua_call_id callId;
    pj_status_t st = pjsua_call_make_call(self.accId, &dst, &opt, NULL, NULL, &callId);
    if (st != PJ_SUCCESS) {
        [self.delegate sipEvent:@"failed" peer:nil
                        message:[NSString stringWithFormat:@"dial failed (%d)", st]];
        return;
    }
    self.callId = callId;
    [self.delegate sipEvent:@"connecting" peer:nil message:nil];
}

- (void)unregister {
    [self stopStats];
    if (self.accId != PJSUA_INVALID_ID) {
        pjsua_acc_set_registration(self.accId, PJ_FALSE);
        pjsua_acc_del(self.accId);
        self.accId = PJSUA_INVALID_ID;
    }
    self.callId = PJSUA_INVALID_ID;
    [self.delegate sipEvent:@"idle" peer:nil message:nil];
}

- (void)dispose {
    [self stopStats];
    if (self.engineUp) {
        if (self.accId != PJSUA_INVALID_ID) {
            pjsua_acc_set_registration(self.accId, PJ_FALSE);
            pjsua_acc_del(self.accId);
            self.accId = PJSUA_INVALID_ID;
        }
        pjsua_destroy();
        self.engineUp = NO;
    }
    if (gSip == self) gSip = nil;
}

- (void)handleCallDisconnected {
    if (self.callSlot != PJSUA_INVALID_ID) {
        pjsua_conf_adjust_rx_level(self.callSlot, 1.0f);
    }
    self.callSlot = PJSUA_INVALID_ID;
    self.duckLevel = 1.0f;
    self.lastAppliedDuckLevel = -1.0f;
    self.lastMicActiveAt = 0.0;
    self.callId = PJSUA_INVALID_ID;
    [self clearSpeakerOverride];
    [self stopStats];
    [self.delegate sipEvent:@"registered" peer:nil message:nil];
}

#pragma mark - Stats

- (void)startStats {
    if (self.callId == PJSUA_INVALID_ID) return;
    [self stopStats];
    __weak StationSip *weakSelf = self;
    self.fastTimer = [NSTimer scheduledTimerWithTimeInterval:0.066 repeats:YES block:^(NSTimer *t) {
        [weakSelf emitLevels];
    }];
    self.slowTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        [weakSelf emitFullStats];
    }];
}

- (void)stopStats {
    [self.fastTimer invalidate];
    self.fastTimer = nil;
    [self.slowTimer invalidate];
    self.slowTimer = nil;
}

- (void)emitLevels {
    if (self.callId == PJSUA_INVALID_ID) return;
    unsigned micTx = 0, micRx = 0, callTx = 0, callRx = 0;
    pjsua_conf_get_signal_level(0, &micTx, &micRx);
    // Sound-device RX is the local mic feeding the bridge; sound-device TX is
    // the playback going out to the speaker. Duck the call's RX while the mic
    // is active so speaker bleed does not loop back into the conference.
    [self updateDuckingForMicLevel:level_to_dbfs(micRx)];

    pjsua_call_info ci;
    if (pjsua_call_get_info(self.callId, &ci) == PJ_SUCCESS) {
        for (unsigned i = 0; i < ci.media_cnt; i++) {
            if (ci.media[i].type == PJMEDIA_TYPE_AUDIO &&
                ci.media[i].status == PJSUA_CALL_MEDIA_ACTIVE) {
                pjsua_conf_port_id slot = ci.media[i].stream.aud.conf_slot;
                if (slot != PJSUA_INVALID_ID) {
                    pjsua_conf_get_signal_level(slot, &callTx, &callRx);
                }
                break;
            }
        }
    }

    // pjsua conf levels: the call port's tx level is our microphone going out,
    // the sound-device port's tx level is the remote audio going to playback.
    double tx = level_to_dbfs(callTx);
    double rx = level_to_dbfs(micTx);
    // Instant attack, ~1.7 dB per 66 ms decay.
    self.txLevel = tx > self.txLevel - 1.7 ? tx : MAX(self.txLevel - 1.7, -60.0);
    self.rxLevel = rx > self.rxLevel - 1.7 ? rx : MAX(self.rxLevel - 1.7, -60.0);

    [self.delegate sipStats:@{
        @"jitterMs": @0.0,
        @"rttMs": @0.0,
        @"packetsLost": @0,
        @"txPayloadBytes": @0,
        @"rxPayloadBytes": @0,
        @"codec": @"",
        @"audioLevelDb": @[@(self.txLevel), @(self.txLevel)],
        @"rxAudioLevelDb": @[@(self.rxLevel), @(self.rxLevel)],
    }];
}

- (void)beginDuckingOnSlot:(pjsua_conf_port_id)slot {
    self.callSlot = slot;
    self.duckLevel = kSipRxGain;
    self.lastAppliedDuckLevel = kSipRxGain;
    self.lastMicActiveAt = 0.0;
    pjsua_conf_adjust_rx_level(slot, kSipRxGain);
}

- (void)updateDuckingForMicLevel:(double)micDb {
    if (self.callSlot == PJSUA_INVALID_ID) return;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (micDb >= -30.0) {
        self.lastMicActiveAt = now;
    }
    BOOL holding = (now - self.lastMicActiveAt) <= 0.250;
    BOOL talking = micDb >= -38.0 && (micDb >= -30.0 || holding);
    float target = talking ? (kSipRxGain * 0.55f) : kSipRxGain;

    float next;
    if (target < self.duckLevel) {
        next = fmaxf(target, self.duckLevel - 0.15f);
    } else {
        next = fminf(target, self.duckLevel + 0.06f);
    }
    self.duckLevel = next;

    if (fabsf(next - self.lastAppliedDuckLevel) >= 0.005f) {
        pjsua_conf_adjust_rx_level(self.callSlot, next);
        self.lastAppliedDuckLevel = next;
    }
}

- (void)emitFullStats {
    if (self.callId == PJSUA_INVALID_ID) return;

    double jitterMs = 0.0;
    double rttMs = 0.0;
    int lost = 0;
    long long txBytes = 0;
    long long rxBytes = 0;

    pjsua_stream_stat st;
    if (pjsua_call_get_stream_stat(self.callId, 0, &st) == PJ_SUCCESS) {
        jitterMs = (double)st.rtcp.rx.jitter.mean / 1000.0;
        rttMs = (double)st.rtcp.rtt.mean / 1000.0;
        lost = (int)st.rtcp.rx.loss;
        txBytes = (long long)st.rtcp.tx.bytes;
        rxBytes = (long long)st.rtcp.rx.bytes;
    }

    NSString *codec = self.codecPref ?: @"OPUS";
    pjsua_stream_info si;
    if (pjsua_call_get_stream_info(self.callId, 0, &si) == PJ_SUCCESS) {
        NSString *name = [NSString stringWithUTF8String:si.info.aud.fmt.encoding_name.ptr];
        NSString *upper = name.uppercaseString;
        if ([upper containsString:@"OPUS"]) codec = @"OPUS";
        else if ([upper containsString:@"G722"]) codec = @"G.722";
        else if ([upper containsString:@"PCMU"] || [upper containsString:@"PCMA"]) codec = @"G.711";
        else if (name.length) codec = name;
    }

    [self.delegate sipStats:@{
        @"jitterMs": @(jitterMs),
        @"rttMs": @(rttMs),
        @"packetsLost": @(lost),
        @"txPayloadBytes": @(txBytes),
        @"rxPayloadBytes": @(rxBytes),
        @"codec": codec,
        @"audioLevelDb": @[@(self.txLevel), @(self.txLevel)],
        @"rxAudioLevelDb": @[@(self.rxLevel), @(self.rxLevel)],
    }];
}

@end
