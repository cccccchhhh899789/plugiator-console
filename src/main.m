//
//  ASXConsole.m — Plugiator ASX 控制台
//  用电脑通过 USB MIDI 给 Use Audio Plugiator ASX 音源板发消息：
//    · 切插件（Program Change 101–108 + 一个音确认）
//    · 切预设（Program Change 1–100）
//    · 调参数（任意 CC# + 值）
//
//  依据：Plugiator ASX User Manual v1.00（2008）
//    p16  Loading Plug-ins：PC 101–108 + any Note 加载插件
//    p17  Changing Presets：PC 1–100 加载预设；PC 109–127 无效
//    p52+ MIDI Implementation Tables：每个插件的 CC→参数表
//
//  构建：bash build.sh
//

#import <Cocoa/Cocoa.h>
#import <CoreMIDI/CoreMIDI.h>
#import "KnobView.h"

// 手册 p16 的插件表：PC 号 → 名字
static NSString *const kPluginNames[] = {
    @"MINIMAX", @"Lightwave", @"B4000", @"Vocodizer",
    @"Prodyssey", @"Pro-12", @"Fmagia", @"Drums'n'Bass"
};
static const NSInteger kPluginCount = 8;
static const NSInteger kPluginPCBase = 101;   // 101..108
static const NSInteger kPresetCount = 100;     // PC 1..100

// 翻转容器：y 向下，行 0 在顶部（isFlipped 必须覆写方法，不能当属性赋值）
@interface CMENFlippedView : NSView
@end
@implementation CMENFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface ASXConsole : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) NSPopUpButton *destPop;
@property(nonatomic, strong) NSPopUpButton *pluginPop;
@property(nonatomic, strong) NSPopUpButton *presetPop;
@property(nonatomic, strong) NSPopUpButton *channelPop;
@property(nonatomic, strong) NSTextField *ccField;
@property(nonatomic, strong) NSSlider *ccSlider;
@property(nonatomic, strong) NSTextField *valueLabel;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSTextView *logView;

// 旋钮 + 搜索
@property(nonatomic, strong) NSView *knobRow;   // 旋钮容器（手动布局）
@property(nonatomic, strong) NSScrollView *knobScroll;
@property(nonatomic, strong) NSTextField *searchField;
@property(nonatomic, strong) NSPopUpButton *searchPop;
@property(nonatomic, strong) NSArray<NSDictionary *> *allTables;   // 每个插件 {plugin, pc, cc:[{cc,name}]}

@property(nonatomic, assign) MIDIClientRef client;
@property(nonatomic, assign) MIDIPortRef outPort;
@property(nonatomic, strong) NSMutableArray<NSNumber *> *destinations;   // @(MIDIEndpointRef)
@property(nonatomic, strong) NSMutableArray<NSString *> *destNames;
@property(nonatomic, assign) CFAbsoluteTime lastDumpAt;   // 上次收到整包 dump 的时刻(抑制尾巴覆盖汇总提示)
@property(nonatomic, assign) MIDIPortRef inPort;   // 收板子回报的端口(本 SDK 只有 MIDIPortRef 没有 MIDIInputPortRef)   // 收板子回报（旋钮/预设 dump）
@property(nonatomic, assign) MIDIEndpointRef srcEp;     // 已连接的板子 source
- (NSInteger)armedCC;
- (KnobView *)knobWithCC:(NSInteger)cc;
- (void)ccFieldChanged:(id)sender;
- (void)applyIncomingCCs:(NSArray<NSArray<NSNumber *> *> *)pairs;
- (void)refreshSources;
@end

// 收板子回报：只解析 CC(0xB0–0xBF)，交给主线程同步 UI。
// 切预设/切插件的整包 dump（约 90 条 CC）也从这里进来。
// 注意：UI 只改显示不回发（knob.setValue / slider.setDoubleValue 都不触发 action），无环路。
static void asxInputProc(const MIDIPacketList *plist, void *refCon, void *srcConnRefCon) {
    (void)srcConnRefCon;
    ASXConsole *me = (__bridge ASXConsole *)refCon;
    if (!me) return;
    NSMutableArray<NSArray<NSNumber *> *> *pairs = [NSMutableArray array];
    const MIDIPacket *pk = &plist->packet[0];
    for (UInt32 n = 0; n < plist->numPackets; n++) {
        const uint8_t *d = pk->data;
        NSUInteger len = pk->length, i = 0;
        uint8_t status = 0, dbuf[2];
        int have = 0, need = 0;
        while (i < len) {
            uint8_t b = d[i++];
            if (b & 0x80) {
                if (b == 0xF0) {                      // sysex：跳到 F7（dump 尾巴有）
                    while (i < len) { if (d[i++] == 0xF7) break; }
                    status = 0; have = 0; continue;
                }
                if (b >= 0xF8) { status = 0; have = 0; continue; }   // 实时单字节
                status = b; have = 0;
                uint8_t hi = (uint8_t)(b & 0xF0);
                need = (hi == 0xC0 || hi == 0xD0) ? 1 : 2;
                continue;
            }
            if (!status || (status & 0xF0) == 0xF0) continue;
            dbuf[have++] = b;
            if (have >= need) {
                if ((status & 0xF0) == 0xB0 && need == 2 && dbuf[0] <= 127 && dbuf[1] <= 127) {
                    [pairs addObject:@[@(dbuf[0]), @(dbuf[1])]];
                }
                have = 0;                             // running status 继续
            }
        }
        pk = MIDIPacketNext(pk);
    }
    if (pairs.count == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [me applyIncomingCCs:pairs]; });
}

@implementation ASXConsole {
    MIDIClientRef _client;
    MIDIPortRef    _outPort;
}

- (void)log:(NSString *)fmt, ... {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"%@", s);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *line = [NSString stringWithFormat:@"%@  %@\n",
                          [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                      dateStyle:NSDateFormatterNoStyle
                                                      timeStyle:NSDateFormatterMediumStyle],
                          s];
        [self.logView.textStorage appendAttributedString:
            [[NSAttributedString alloc] initWithString:line]];
        [self.logView scrollRangeToVisible:
            NSMakeRange(self.logView.textStorage.length, 0)];
    });
}

// ── MIDI 发送 ───────────────────────────────────────────────

- (BOOL)setupMIDI {
    if (MIDIClientCreate(CFSTR("Plugiator ASX Console"), NULL, NULL, &_client) != noErr) {
        [self log:@"✗ MIDIClientCreate 失败"];
        return NO;
    }
    if (MIDIOutputPortCreate(_client, CFSTR("out"), &_outPort) != noErr) {
        [self log:@"✗ MIDIOutputPortCreate 失败"];
        return NO;
    }
    if (MIDIInputPortCreate(_client, CFSTR("in"), asxInputProc, (__bridge void *)self, &_inPort) != noErr) {
        [self log:@"✗ MIDIInputPortCreate 失败（板子回报收不到）"];
        _inPort = 0;
    }
    return YES;
}

- (void)sendBytes:(NSData *)data toDest:(MIDIEndpointRef)dest {
    if (!dest || !_outPort) return;
    const void *bytes = data.bytes;
    MIDIPacketList pkt;
    MIDIPacket *pk = MIDIPacketListInit(&pkt);
    pk = MIDIPacketListAdd(&pkt, sizeof(pkt), pk, 0, data.length, bytes);
    OSStatus st = MIDISend(_outPort, dest, &pkt);
    NSMutableString *hex = [NSMutableString string];
    const uint8_t *p = (const uint8_t *)data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02X ", p[i]];
    if (st == noErr) {
        [self log:@"→ %@", [hex stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
    } else {
        [self log:@"✗ 发送失败 (OSStatus %d)", (int)st];
    }
}

// 给状态字节加通道号
- (NSData *)withChannel:(NSData *)raw channel:(uint8_t)ch {
    NSMutableData *d = [raw mutableCopy];
    uint8_t *p = (uint8_t *)d.mutableBytes;
    for (NSUInteger i = 0; i < d.length; i++) {
        if (p[i] >= 0x80 && p[i] < 0xF0) p[i] = (uint8_t)((p[i] & 0xF0) | (ch & 0x0F));
    }
    return d;
}

// ── CC 参数表（从 data/*.json 读） ───────────────────────────────

// 从 App 包里的 Resources/data/ 读所有插件的 CC 表
- (void)loadTables {
    NSBundle *b = [NSBundle mainBundle];
    NSString *dir = [b pathForResource:@"data" ofType:@""];
    if (!dir) {
        // 开发态：直接跑 build/ 时在源码目录找
        dir = [NSBundle mainBundle].bundlePath;
        dir = [dir stringByAppendingPathComponent:@"Contents/Resources/data"];
    }
    NSArray *urls = [NSFileManager.defaultManager
        contentsOfDirectoryAtPath:dir error:nil];
    NSMutableArray<NSDictionary *> *tables = [NSMutableArray array];
    for (NSString *name in [urls sortedArrayUsingSelector:@selector(compare:)]) {
        if (![name hasSuffix:@".json"]) continue;
        NSString *path = [dir stringByAppendingPathComponent:name];
        NSData *raw = [NSData dataWithContentsOfFile:path];
        NSError *err = nil;
        NSDictionary *d = [NSJSONSerialization JSONObjectWithData:raw
                                                          options:0 error:&err];
        if (!d || err) { NSLog(@"读 %@ 失败: %@", path, err); continue; }
        NSMutableArray<NSDictionary *> *cc = [NSMutableArray array];
        for (id item in d[@"cc"]) {
            NSNumber *n = item[@"cc"];
            if (!n) continue;
            [cc addObject:@{@"cc": n, @"name": item[@"name"] ?: @""}];
        }
        [tables addObject:@{
            @"plugin": d[@"plugin"] ?: @"",
            @"pc":     d[@"pc"] ?: @0,
            @"cc":     cc
        }];
    }
    self.allTables = [tables copy];
    [self log:@"载入 CC 参数表 %lu 份（%@）", (unsigned long)tables.count,
          [tables valueForKey:@"plugin"]];
}

// 当前选中的插件对应的表（下拉第 0 项是「未选择」，真实插件从 1 开始）
- (NSDictionary *)currentTable {
    NSInteger idx = self.pluginPop.indexOfSelectedItem - 1;
    if (idx < 0 || (NSUInteger)idx >= kPluginCount) return nil;
    NSString *want = kPluginNames[idx];
    for (NSDictionary *t in self.allTables) {
        if ([[t[@"plugin"] lowercaseString] isEqualToString:[want lowercaseString]]) return t;
    }
    return nil;
}

// CC# 框：空/非法 = 「未选择」(-1)，合法 0–127 = 已选中
- (NSInteger)armedCC {
    NSString *t = [self.ccField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (t.length == 0) return -1;
    if ([t rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location != NSNotFound) return -1;
    NSInteger v = t.integerValue;
    return (v >= 0 && v <= 127) ? v : -1;
}

- (KnobView *)knobWithCC:(NSInteger)cc {
    for (NSView *v in self.knobRow.subviews) {
        if ([v isKindOfClass:[KnobView class]] && ((KnobView *)v).ccNumber == (int)cc) return (KnobView *)v;
    }
    return nil;
}

// 板子回报 → 同步 UI（显示层，绝不回发）
- (void)applyIncomingCCs:(NSArray<NSArray<NSNumber *> *> *)pairs {
    NSInteger armed = [self armedCC];
    NSInteger lastCC = -1, lastVal = -1;
    for (NSArray<NSNumber *> *pv in pairs) {
        NSInteger cc = pv[0].integerValue, val = pv[1].integerValue;
        lastCC = cc; lastVal = val;
        KnobView *k = [self knobWithCC:cc];
        if (k) k.value = (int)val;                    // setValue 不触发 onChange
        if (armed == cc) {
            [self.ccSlider setDoubleValue:(double)val];   // 不触发 action
            self.valueLabel.stringValue = [NSString stringWithFormat:@"%ld", (long)val];
        }
    }
    if (pairs.count >= 5) {
        self.statusLabel.stringValue = [NSString stringWithFormat:
            @"板子回报 %lu 个参数 → 旋钮/滑条已同步", (unsigned long)pairs.count];
    } else if (lastCC >= 0) {
        // dump 之后 0.8 秒内的零星尾巴包不覆盖「板子回报 N 个参数」的汇总提示
        if (CFAbsoluteTimeGetCurrent() - self.lastDumpAt > 0.8) {
            self.statusLabel.stringValue = [NSString stringWithFormat:
                @"板子 → CC%ld = %ld", (long)lastCC, (long)lastVal];
        }
    }
}

// 连板子的 source，收它的回报（切预设/切插件 dump、物理旋钮）
- (void)refreshSources {
    if (!_inPort) return;
    MIDIEndpointRef found = 0;
    NSString *foundName = nil;
    ItemCount ns = MIDIGetNumberOfSources();
    for (ItemCount i = 0; i < ns; i++) {
        MIDIEndpointRef ep = MIDIGetSource(i);
        if (!ep) continue;
        CFStringRef cf = NULL;
        MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &cf);
        NSString *name = cf ? (__bridge NSString *)cf : @"";
        if (cf) CFRelease(cf);
        if ([name containsString:@"ASX"]) { found = ep; foundName = name; break; }
    }
    if (!found || found == _srcEp) return;
    if (_srcEp) MIDIPortDisconnectSource(_inPort, _srcEp);
    if (MIDIPortConnectSource(_inPort, found, NULL) == noErr) {
        _srcEp = found;
        [self log:@"已监听板子回报：%@", foundName];
    } else {
        [self log:@"✗ 连板子回报源失败"];
    }
}

// ── 旋钮：实时发送 ─────────────────────────────────────────────

// 用旋钮的当前值发一次 CC（拖动即发，松手补发）
- (void)sendKnobValue:(KnobView *)knob {
    MIDIEndpointRef dest = [self currentDest];
    if (!dest) return;
    uint8_t ch = (uint8_t)self.channelPop.indexOfSelectedItem;
    [self sendBytes:[self withChannel:[NSData dataWithBytes:(uint8_t[]){
        0xB0, (uint8_t)knob.ccNumber, (uint8_t)knob.value} length:3] channel:ch]
             toDest:dest];
    // 同号滑条跟着走（setDoubleValue 不触发 action，不会二次发送）
    if ([self armedCC] == (NSInteger)knob.ccNumber) {
        [self.ccSlider setDoubleValue:knob.value];
        self.valueLabel.stringValue = [NSString stringWithFormat:@"%d", knob.value];
    }
}

// 按当前插件重建旋钮面板：取表里前 kMaxKnobs 条（CC 号小的通常是常用项）
- (void)rebuildKnobs {
    // 清空旧旋钮
    for (NSView *v in [self.knobRow subviews]) [v removeFromSuperview];

    NSDictionary *t = [self currentTable];
    if (!t) {
        // 区分「还没选插件」和「选了但手册没表」两种空面板
        self.statusLabel.stringValue = (self.pluginPop.indexOfSelectedItem < 1)
            ? @"未选择插件 —— 选完自动发送，旋钮面板随之加载"
            : @"该插件手册里没有 CC 参数表";
        return;
    }
    NSArray *cc = t[@"cc"];
    static const NSInteger kMaxKnobs = 12;
    static const NSInteger kPerRow = 4;
    NSMutableArray<KnobView *> *made = [NSMutableArray array];
    for (NSInteger i = 0; i < cc.count && i < kMaxKnobs; i++) {
        NSDictionary *e = cc[i];
        NSInteger ccNum = [(NSNumber *)e[@"cc"] integerValue];
        KnobView *k = [[KnobView alloc] initWithFrame:NSZeroRect];
        k.label = e[@"name"] ?: [NSString stringWithFormat:@"CC%ld", (long)ccNum];
        k.ccLabel = [NSString stringWithFormat:@"CC%ld", (long)ccNum];
        k.ccNumber = (int)ccNum;
        k.value = 64;
        k.onChange = ^(KnobView *knob) { [self sendKnobValue:knob]; };
        [made addObject:k];
    }
    // 手动摆位置：每行 4 个，不依赖 Auto Layout（本机 SDK 的类方法约束接口不全）
    CGFloat kW = 96, kH = 108, kGap = 8, kPad = 4;
    NSInteger idx = 0;
    for (NSInteger i = 0; i < (NSInteger)made.count; i++) {
        NSInteger row = i / kPerRow;
        NSInteger col = i % kPerRow;
        KnobView *kn = made[i];
        kn.frame = NSMakeRect(col * (kW + kGap) + kPad, row * (kH + kGap) + kPad, kW, kH);
        [self.knobRow addSubview:kn];
    }
    // 容器必须撑到能装下所有旋钮，否则 documentView 是 0×0，滚动区一片空白
    NSInteger rows = (made.count + kPerRow - 1) / kPerRow;
    if (rows < 1) rows = 1;
    CGFloat contW = kPerRow * (kW + kGap) + kPad;
    CGFloat contH = rows * (kH + kGap) + kPad;
    self.knobRow.frame = NSMakeRect(0, 0, contW, contH);
    self.statusLabel.stringValue = [NSString stringWithFormat:
        @"旋钮 %ld 个（拖动即实时发 CC）", (long)made.count];
}

// 搜索：跨所有插件的 CC 表按名字/CC 号筛
- (void)rebuildSearchResults {
    NSString *q = [self.searchField.stringValue stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceCharacterSet];
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (NSDictionary *t in self.allTables) {
        for (NSDictionary *e in t[@"cc"]) {
            NSInteger ccNum = [(NSNumber *)e[@"cc"] integerValue];
            NSString *nm = e[@"name"] ?: @"";
            if (!q.length) { [items addObject:[NSString stringWithFormat:@"%@  CC%ld %@", t[@"plugin"], (long)ccNum, nm]]; continue; }
            BOOL hit = [[nm lowercaseString] rangeOfString:q.lowercaseString].location != NSNotFound
                  || [[NSString stringWithFormat:@"%ld", (long)ccNum] rangeOfString:q].location != NSNotFound;
            if (hit) {
                [items addObject:[NSString stringWithFormat:@"%@  CC%ld %@", t[@"plugin"], (long)ccNum, nm]];
            }
        }
    }
    if (items.count > 200) [items removeObjectsInRange:NSMakeRange(200, items.count - 200)];
    [self.searchPop removeAllItems];
    if (items.count == 0) {
        [self.searchPop addItemWithTitle:@"（无匹配结果）"];
    } else {
        for (NSString *s in items) [self.searchPop addItemWithTitle:s];
        [self.searchPop selectItemAtIndex:0];
    }
}

// 点搜索结果 → 把 CC 号填进手工 CC 区，用户再拖滑杆/点发送
- (void)searchPicked {
    NSInteger i = self.searchPop.indexOfSelectedItem;
    if (i < 0) return;
    NSString *title = [[self.searchPop.itemArray objectAtIndex:(NSUInteger)i] title];
    NSArray *parts = [title componentsSeparatedByString:@"CC"];
    if (parts.count < 2) return;
    NSString *ccStr = [[parts[1] componentsSeparatedByString:@" "] firstObject];
    self.ccField.stringValue = ccStr ?: @"";
    [self ccFieldChanged:nil];        // 与手输一致：有同号旋钮则滑条对齐它的值
}

- (MIDIEndpointRef)currentDest {
    NSInteger idx = self.destPop.indexOfSelectedItem;
    if (idx < 0 || (NSUInteger)idx >= self.destinations.count) return 0;
    return (MIDIEndpointRef)[self.destinations[(NSUInteger)idx] unsignedIntValue];
}

// 切插件：PC 101–108 + 一个音（手册 p16 要求「PC + 弹一个音确认」）
- (void)doSwitchPlugin {
    MIDIEndpointRef dest = [self currentDest];
    if (!dest) { [self log:@"✗ 没有选 MIDI 目标"]; return; }
    NSInteger idx = self.pluginPop.indexOfSelectedItem - 1;
    if (idx < 0) return;                       // 「未选择」，什么都不发
    NSInteger pc = kPluginPCBase + idx;
    uint8_t ch = (uint8_t)self.channelPop.indexOfSelectedItem;
    [self sendBytes:[self withChannel:[NSData dataWithBytes:(uint8_t[]){0xC0, (uint8_t)pc} length:2] channel:ch]
             toDest:dest];
    // 确认用的那个音：中央 C，弹完立刻放掉
    [self sendBytes:[self withChannel:[NSData dataWithBytes:(uint8_t[]){0x90, 0x3C, 0x40} length:3] channel:ch]
             toDest:dest];
    [self sendBytes:[self withChannel:[NSData dataWithBytes:(uint8_t[]){0x80, 0x3C, 0x00} length:3] channel:ch]
             toDest:dest];
    [self log:@"切到插件：%@ (PC %ld)", kPluginNames[idx], (long)pc];
}

// 切预设：PC 1–100（「未选择」在第 0 项，真实预设 N 在第 N 项）
- (void)doSwitchPreset {
    MIDIEndpointRef dest = [self currentDest];
    if (!dest) { [self log:@"✗ 没有选 MIDI 目标"]; return; }
    NSInteger pc = self.presetPop.indexOfSelectedItem;
    if (pc < 1) return;                        // 「未选择」，什么都不发
    uint8_t ch = (uint8_t)self.channelPop.indexOfSelectedItem;
    [self sendBytes:[self withChannel:[NSData dataWithBytes:(uint8_t[]){0xC0, (uint8_t)pc} length:2] channel:ch]
             toDest:dest];
    [self log:@"切到预设 %ld", (long)pc];
}

// 发 CC
- (void)doSendCC {
    MIDIEndpointRef dest = [self currentDest];
    if (!dest) { [self log:@"✗ 没有选 MIDI 目标"]; return; }
    NSInteger cc = [self armedCC];
    if (cc < 0) { [self log:@"✗ CC 未选择（先填 0–127）"]; return; }
    NSInteger val = (NSInteger)llround(self.ccSlider.doubleValue);
    uint8_t ch = (uint8_t)self.channelPop.indexOfSelectedItem;
    [self sendBytes:[self withChannel:[NSData dataWithBytes:(uint8_t[]){0xB0, (uint8_t)cc, (uint8_t)val} length:3] channel:ch]
             toDest:dest];
    [self log:@"CC#%ld = %ld", (long)cc, (long)val];
}

// 枚举 MIDI 目标端口。走「设备→实体」的路，而不是 MIDIGetNumberOfDestinations()：
// 在本机 App 里旧式全局 API 返回 0，但设备/实体 API 能正确列出。
- (void)refreshDestinations:(id)sender {
    NSMutableArray<NSNumber *> *found = [NSMutableArray array];
    NSMutableArray<NSString *> *names = [NSMutableArray array];

    ItemCount nd = MIDIGetNumberOfDestinations();
    for (ItemCount i = 0; i < nd; i++) {
        MIDIEndpointRef ep = MIDIGetDestination(i);
        if (!ep) continue;
        CFStringRef cf = NULL;
        MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &cf);
        NSString *name = cf ? (__bridge NSString *)cf : @"未知";
        if (cf) CFRelease(cf);
        [found addObject:@(ep)];
        [names addObject:name];
    }

    self.destinations = found;
    self.destNames = names;
    [self.destPop removeAllItems];
    for (NSString *n in names) [self.destPop addItemWithTitle:n];
    for (NSUInteger i = 0; i < names.count; i++) {
        if ([names[i] containsString:@"ASX"]) { [self.destPop selectItemAtIndex:(NSInteger)i]; break; }
    }

    if (names.count == 0) {
        self.statusLabel.stringValue = @"没找到任何 MIDI 输出端口（板子接了吗？）";
        [self log:@"✗ 没找到任何 MIDI 输出端口"];
    } else {
        NSInteger idx = self.destPop.indexOfSelectedItem;
        self.statusLabel.stringValue = [NSString stringWithFormat:@"目标：%@",
                                        idx >= 0 ? names[(NSUInteger)idx] : @"—"];
        [self log:@"找到 %lu 个 MIDI 目标端口", (unsigned long)names.count];
    }
    [self refreshSources];                      // 顺带把板子回报源连上
}

// ── UI ──────────────────────────────────────────────────────

- (NSTextField *)label:(NSString *)text {
    NSTextField *l = [NSTextField labelWithString:text];
    l.alignment = NSTextAlignmentRight;
    return l;
}

- (NSView *)buildWindow {
    // 目标
    self.destPop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.destPop.target = self;
    self.destPop.action = @selector(refreshDestinations:);

    NSButton *refreshBtn = [NSButton buttonWithTitle:@"重新扫描端口"
                                              target:self action:@selector(refreshDestinations:)];

    // 插件（选完即发；第一项「未选择」为默认，启动不发任何东西）
    self.pluginPop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.pluginPop.target = self;
    self.pluginPop.action = @selector(pluginChanged:);
    [self.pluginPop addItemWithTitle:@"未选择"];
    for (NSInteger i = 0; i < kPluginCount; i++) {
        [self.pluginPop addItemWithTitle:[NSString stringWithFormat:@"%ld  %@",
                                        (long)(kPluginPCBase + i), kPluginNames[i]]];
    }
    [self.pluginPop selectItemAtIndex:0];

    // 预设（选完即发）
    self.presetPop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.presetPop.target = self;
    self.presetPop.action = @selector(presetChanged:);
    [self.presetPop addItemWithTitle:@"未选择"];
    for (NSInteger i = 0; i < kPresetCount; i++) {
        [self.presetPop addItemWithTitle:[NSString stringWithFormat:@"预设 %ld (PC %ld)",
                                         (long)(i+1), (long)(i+1)]];
    }
    [self.presetPop selectItemAtIndex:0];

    // 通道
    self.channelPop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSInteger i = 0; i < 16; i++) {
        [self.channelPop addItemWithTitle:[NSString stringWithFormat:@"通道 %ld", (long)(i+1)]];
    }

    // CC
    self.ccField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 54, 22)];
    self.ccField.stringValue = @"";                 // 默认「未选择」
    self.ccField.placeholderString = @"未选择";
    self.ccField.alignment = NSTextAlignmentRight;
    self.ccField.target = self;
    self.ccField.action = @selector(ccFieldChanged:);
    self.ccSlider = [NSSlider sliderWithValue:80 minValue:0 maxValue:127
                                        target:self action:@selector(sliderMoved:)];
    self.ccSlider.continuous = YES;                 // 拖动中实时发
    self.valueLabel = [NSTextField labelWithString:@"80"];
    NSButton *ccBtn = [NSButton buttonWithTitle:@"发这个 CC"
                                         target:self action:@selector(doSendCC)];

    self.statusLabel = [NSTextField labelWithString:@""];
    self.statusLabel.textColor = NSColor.secondaryLabelColor;

    // 旋钮面板：容器 + 滚动（本 SDK 的 NSStackView 动态接口不全，用普通容器手动摆）
    self.knobRow = [[CMENFlippedView alloc] initWithFrame:NSZeroRect];   // y 向下，行 0 在顶部
    self.knobScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.knobScroll.hasVerticalScroller = YES;
    self.knobScroll.hasHorizontalScroller = YES;
    self.knobScroll.borderType = NSBezelBorder;
    self.knobScroll.documentView = self.knobRow;
    // NSScrollView 没有固有高度，不给约束会被 StackView 压成 0（旋钮全看不见）
    [self.knobScroll setContentHuggingPriority:NSLayoutPriorityDefaultLow
                                forOrientation:NSLayoutConstraintOrientationVertical];
    [self.knobScroll.heightAnchor constraintEqualToConstant:240].active = YES;

    // 搜索
    self.searchField = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 180, 22)];
    self.searchField.placeholderAttributedString =
        [[NSAttributedString alloc] initWithString:@"搜参数名或 CC 号"];
    self.searchField.target = self;
    self.searchField.action = @selector(rebuildSearchResults);

    self.searchPop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.searchPop addItemWithTitle:@"（点右侧搜索框）"];
    self.searchPop.target = self;
    self.searchPop.action = @selector(searchPicked);

    NSButton *sendSelected = [NSButton buttonWithTitle:@"填入 CC 区"
                                                target:self action:@selector(searchPicked)];

    // 日志
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    NSTextView *tv = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 420, 120)];
    tv.editable = NO;
    tv.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    scroll.documentView = tv;
    self.logView = tv;

    NSStackView *s = [NSStackView stackViewWithViews:@[
        [self label:@"MIDI 目标"], self.destPop, refreshBtn,
        [self label:@"插件"],     self.pluginPop,
        [self label:@"预设"],     self.presetPop,
        [self label:@"通道"],     self.channelPop,
        [self label:@"CC#"],      self.ccField, self.ccSlider, self.valueLabel, ccBtn,
        [self label:@"常用旋钮(实时发)"], self.knobScroll,
        [self label:@"搜索 CC 参数"], self.searchField, self.searchPop, sendSelected,
        self.statusLabel,
        scroll
    ]];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.alignment = NSLayoutAttributeLeading;
    s.spacing = 8;
    s.edgeInsets = NSEdgeInsetsMake(14, 16, 14, 16);
    [s setCustomSpacing:14 afterView:self.channelPop];
    s.translatesAutoresizingMaskIntoConstraints = NO;
    return s;
}

- (void)sliderMoved:(id)sender {
    NSInteger val = (NSInteger)llround(self.ccSlider.doubleValue);
    self.valueLabel.stringValue = [NSString stringWithFormat:@"%ld", (long)val];
    NSInteger cc = [self armedCC];
    if (cc < 0) return;                          // 「未选择」→ 只动显示不发送
    MIDIEndpointRef dest = [self currentDest];
    if (!dest) return;
    uint8_t ch = (uint8_t)self.channelPop.indexOfSelectedItem;
    [self sendBytes:[self withChannel:[NSData dataWithBytes:(uint8_t[]){
        0xB0, (uint8_t)cc, (uint8_t)val} length:3] channel:ch]
             toDest:dest];
    KnobView *k = [self knobWithCC:cc];           // 同号旋钮跟着转
    if (k && k.value != (int)val) {
        k.value = (int)val;
        [k setNeedsDisplay:YES];
    }
}

// CC# 框回车/失焦：确认选中，且有同号旋钮时滑条对齐旋钮当前值
- (void)ccFieldChanged:(id)sender {
    NSInteger cc = [self armedCC];
    if (cc < 0) {
        self.statusLabel.stringValue = @"CC 未选择 —— 滑条不发送（填 0–127 生效）";
        return;
    }
    KnobView *k = [self knobWithCC:cc];
    if (k) {
        [self.ccSlider setDoubleValue:k.value];
        self.valueLabel.stringValue = [NSString stringWithFormat:@"%d", k.value];
        self.statusLabel.stringValue = [NSString stringWithFormat:
            @"CC%ld = %@（与旋钮联动，拖滑条即发送）", (long)cc, k.label];
    } else {
        self.statusLabel.stringValue = [NSString stringWithFormat:
            @"CC%ld 已选中（拖滑条即发送）", (long)cc];
    }
}

// 插件切换 → 选完即发 + 重建旋钮面板
- (void)pluginChanged:(id)sender {
    if (self.pluginPop.indexOfSelectedItem < 1) {   // 「未选择」只清面板
        [self rebuildKnobs];
        return;
    }
    [self doSwitchPlugin];
    [self rebuildKnobs];
}

// 预设切换 → 选完即发
- (void)presetChanged:(id)sender {
    [self doSwitchPreset];
}

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    [self setupMIDI];
    [self loadTables];              // CC 参数表（旋钮 + 搜索的数据源）

    // 高度要装得下：表单 + 240pt 旋钮区 + 日志，否则底部会被裁掉
    NSRect frame = NSMakeRect(0, 0, 470, 900);
    NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                               styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                                 backing:NSBackingStoreBuffered
                                                   defer:NO];
    win.title = @"Plugiator ASX 控制台";
    win.contentView = [self buildWindow];
    [self rebuildKnobs];           // 默认插件的旋钮
    [self rebuildSearchResults];    // 搜索结果（全部 CC）
    [self refreshDestinations:nil];
    // MIDIServer 起来/枚举有延迟：定时重扫，直到拿到端口为止
    __block int tries = 0;
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *tm) {
        if (self.destinations.count > 0 || ++tries > 20) { [tm invalidate]; return; }
        [self refreshDestinations:nil];
    }];
    [win center];
    [win makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)applicationWillTerminate:(NSNotification *)n {
    if (_inPort) { if (_srcEp) MIDIPortDisconnectSource(_inPort, _srcEp); MIDIPortDispose(_inPort); }
    if (_outPort) MIDIPortDispose(_outPort);
    if (_client) MIDIClientDispose(_client);
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        ASXConsole *c = [[ASXConsole alloc] init];
        app.delegate = c;
        [app run];
    }
    return 0;
}
