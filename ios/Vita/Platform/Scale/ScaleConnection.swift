import CoreBluetooth
import Foundation
import Observation
import OSLog

/// 阿福体脂秤的蓝牙连接：只在称重页打开时扫描，拿到一次锁定结果就断开。
/// 连上后先握手，秤把没连手机时存下的离线记录逐条发来；存好一条才回确认，秤随即删掉它。
/// 有记录没确认时秤不发实时体重，所以同步完（`isSyncing` 变回 false）才请用户站上去。
@MainActor
@Observable
final class ScaleConnection: NSObject {
    enum Phase: Equatable {
        case idle
        /// 关闭、未授权或设备不支持；附带给用户看的原因。
        case unavailable(String)
        case searching
        case connecting
        /// 已订阅称重数据，等用户站上去。
        case waiting
        case finished
    }

    private(set) var phase: Phase = .idle
    /// 连过但连不上：秤同一时间只接受一台设备，多半是蚂蚁阿福等 App 还连着它。
    private(set) var seemsBusy = false
    /// 已连上，但秤还在吐离线记录（或握手没完）。这期间秤不发实时体重，站上去的那次会被它存成离线记录，
    /// 所以要等同步安静下来再请用户站上去。
    private(set) var isSyncing = false
    /// 最近一帧（实时变化的体重）。
    private(set) var live: ScaleMeasurement?
    /// 每次连接只回调一次锁定结果。
    var onFinal: ((ScaleMeasurement) -> Void)?
    /// 收到一条离线记录；返回 true 表示已存好，才向秤确认（秤会删掉这条）。
    var onOfflineRecord: ((ScaleOfflineRecord) async -> Bool)?
    /// 握手时写进秤的用户资料；没有时只对时、不下发用户。
    var user: ScaleCommand.User?

    private static let deviceName = "AFU-WL-TZ-A1"
    private static let service = CBUUID(string: "FFB0")
    private static let notify = CBUUID(string: "FFB2")
    private static let write = CBUUID(string: "FFB1")
    private static let log = Logger(subsystem: "com.leonardo.vita", category: "scale")

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writer: CBCharacteristic?
    private var delivered = false
    /// 正在保存（或没存成功）的离线记录帧。没确认前秤会每隔一秒多重发同一帧，期间一律忽略。
    private var savingRecord: Data?
    /// 握手指令全部发完。真机上见过：握手中途回离线记录的确认，秤会断开、换地址重连后再也不发数据。
    private var handshakeDone = false
    /// 握手期间收到的离线记录，握手完再处理：不能指望秤一定会重发。
    private var heldRecord: (record: ScaleOfflineRecord, frame: Data)?
    private var syncIdleCheck: Task<Void, Never>?
    /// 最后一条离线记录确认后、或握手完后，这么久没有新记录就当同步完了。
    private static let syncQuietPeriod: Duration = .seconds(2)

    /// 第一次调用时创建 CBCentralManager，系统随之弹出蓝牙授权。
    func start() {
        live = nil
        delivered = false
        seemsBusy = false
        isSyncing = false
        guard let central else {
            central = CBCentralManager(delegate: self, queue: nil)
            return
        }
        scanIfReady(central)
    }

    func stop() {
        central?.stopScan()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        resetSession()
        if phase != .finished { phase = .idle }
    }

    /// 断开或停止时清掉这次连接的状态。
    private func resetSession() {
        writer = nil
        savingRecord = nil
        heldRecord = nil
        handshakeDone = false
        isSyncing = false
        syncIdleCheck?.cancel()
    }

    /// 同步安静一阵、没有记录在存，就可以请用户站上去了。
    private func scheduleSyncIdleCheck() {
        syncIdleCheck?.cancel()
        syncIdleCheck = Task {
            try? await Task.sleep(for: Self.syncQuietPeriod)
            guard !Task.isCancelled, handshakeDone, savingRecord == nil, heldRecord == nil else { return }
            if isSyncing { Self.log.info("offline sync idle") }
            isSyncing = false
        }
    }

    private func scanIfReady(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            phase = .searching
            // 广播包里不一定带 FFB0，按名称或服务过滤。
            central.scanForPeripherals(withServices: nil)
        case .poweredOff: phase = .unavailable("蓝牙已关闭，请在控制中心打开。")
        case .unauthorized: phase = .unavailable("没有蓝牙权限，请在“设置 → Vita”里打开蓝牙。")
        case .unsupported: phase = .unavailable("这台设备不支持蓝牙。")
        default: break
        }
    }

    private func handle(_ measurement: ScaleMeasurement) {
        // 秤开始发实时体重，说明它已经不在同步了。
        isSyncing = false
        live = measurement
        guard measurement.isFinal, !delivered else { return }
        delivered = true
        phase = .finished
        onFinal?(measurement)
        stop()
    }
}

extension ScaleConnection {
    /// 对时、下发用户、签名握手，秤随后吐出离线记录。
    private func handshake(_ peripheral: CBPeripheral) async {
        let now = Date()
        var commands = [ScaleCommand.setTime(now, timeZone: .current)]
        if let user {
            commands += [ScaleCommand.userList(user), ScaleCommand.timeAndUser(user, date: now, timeZone: .current)]
        }
        commands += [ScaleCommand.readSign, ScaleCommand.wakeUp]
        for command in commands {
            guard self.peripheral === peripheral else { return }
            send(command, to: peripheral)
            try? await Task.sleep(for: .milliseconds(60))
        }
        guard self.peripheral === peripheral else { return }
        handshakeDone = true
        if let held = heldRecord {
            heldRecord = nil
            receive(held.record, frame: held.frame, from: peripheral)
        }
        scheduleSyncIdleCheck()
    }

    private func receive(_ record: ScaleOfflineRecord, frame: Data, from peripheral: CBPeripheral) {
        isSyncing = true
        scheduleSyncIdleCheck()
        // 握手没完成前先记下、不确认（握手中途确认会让秤断开），握手完再处理。
        guard handshakeDone else {
            heldRecord = (record, frame)
            return
        }
        // 正在存的这条，秤没收到确认会每隔一秒多重发，忽略。
        guard savingRecord == nil, let onOfflineRecord else { return }
        savingRecord = frame
        Task {
            let saved = await onOfflineRecord(record)
            // 存的时候断开了就不确认，秤下次还会再发。
            guard savingRecord == frame, self.peripheral === peripheral else { return }
            guard saved else {
                // 没存成功：秤不确认就一直卡在这条、也不发实时体重。过一会儿等它重发时再试。
                Self.log.error("offline record not saved, retrying on the next resend")
                try? await Task.sleep(for: .seconds(3))
                if savingRecord == frame { savingRecord = nil }
                return
            }
            savingRecord = nil
            send(ScaleCommand.historyAck, to: peripheral)
            scheduleSyncIdleCheck()
        }
    }

    private func send(_ command: Data, to peripheral: CBPeripheral) {
        guard let writer else { return Self.log.info("no FFB1") }
        let type: CBCharacteristicWriteType = writer.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        Self.log.info("send \(command.map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .public)")
        peripheral.writeValue(command, for: writer, type: type)
    }
}

// queue 为 nil，回调都在主线程。
extension ScaleConnection: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn { peripheral = nil }
        guard phase != .finished else { return }
        scanIfReady(central)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        guard self.peripheral == nil, name == Self.deviceName || services.contains(Self.service) else { return }
        // 和 AFUScale 一致：名称带 Clone 的同服务设备不是秤本身。
        let displayName = name ?? peripheral.name ?? ""
        guard !displayName.contains("Clone") else { return }
        Self.log.info("discovered \(displayName, privacy: .public) \(peripheral.identifier, privacy: .public) services=\(services, privacy: .public)")
        phase = .connecting
        self.peripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral)
        // 系统的连接请求不会超时；连不上就放弃这次，重新扫描。
        Task {
            try? await Task.sleep(for: .seconds(10))
            guard self.peripheral === peripheral, phase == .connecting else { return }
            Self.log.info("connect timed out")
            seemsBusy = true
            central.cancelPeripheralConnection(peripheral)
            self.peripheral = nil
            scanIfReady(central)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Self.log.info("connected")
        peripheral.discoverServices([Self.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil
        scanIfReady(central)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Self.log.info("disconnected \(String(describing: error), privacy: .public)")
        guard self.peripheral != nil else { return }
        // 秤息屏会断开；还没拿到结果就接着找。
        self.peripheral = nil
        resetSession()
        if phase != .finished { scanIfReady(central) }
    }
}

extension ScaleConnection: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Self.log.info("services \(peripheral.services?.map(\.uuid) ?? [], privacy: .public) \(String(describing: error), privacy: .public)")
        for service in peripheral.services ?? [] where service.uuid == Self.service {
            peripheral.discoverCharacteristics([Self.notify, Self.write], for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Self.log.info("characteristics \(service.characteristics?.map(\.uuid) ?? [], privacy: .public) \(String(describing: error), privacy: .public)")
        writer = service.characteristics?.first { $0.uuid == Self.write }
        for characteristic in service.characteristics ?? [] where characteristic.uuid == Self.notify {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Self.log.info("notify \(characteristic.isNotifying) \(String(describing: error), privacy: .public)")
        // 订阅真正生效后才算连上。
        if characteristic.uuid == Self.notify, characteristic.isNotifying {
            phase = .waiting
            seemsBusy = false
            handshakeDone = false
            // 秤收到对时就开始吐离线记录；没有记录时握手完 2 秒就算同步完。
            isSyncing = true
            Task { await handshake(peripheral) }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let data = characteristic.value {
            Self.log.info("frame \(data.map { String(format: "%02x", $0) }.joined(separator: " "), privacy: .public)")
        }
        if let data = characteristic.value, data.count >= 20, data[18] == 0xDF, data[2] == 0x06 {
            send(ScaleCommand.replySign, to: peripheral)
        }
        if let data = characteristic.value, let record = ScalePacketParser.parseOfflineRecord(data) {
            return receive(record, frame: data, from: peripheral)
        }
        guard characteristic.uuid == Self.notify, let data = characteristic.value,
              let measurement = ScalePacketParser.parse(data) else { return }
        handle(measurement)
    }
}
