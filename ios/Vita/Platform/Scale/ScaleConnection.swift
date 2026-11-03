import CoreBluetooth
import Foundation
import Observation
import OSLog

/// 阿福体脂秤的蓝牙连接：只在称重页打开时扫描，拿到一次锁定结果就断开。
/// 连上后先握手，秤把没连手机时存下的离线记录逐条发来；存好一条才回确认，秤随即删掉它。
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

    /// 第一次调用时创建 CBCentralManager，系统随之弹出蓝牙授权。
    func start() {
        live = nil
        delivered = false
        seemsBusy = false
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
        writer = nil
        savingRecord = nil
        handshakeDone = false
        if phase != .finished { phase = .idle }
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
        if self.peripheral === peripheral { handshakeDone = true }
    }

    private func receive(_ record: ScaleOfflineRecord, frame: Data, from peripheral: CBPeripheral) {
        // 握手没完成前先不处理：秤没收到确认会每隔一秒多重发。
        guard handshakeDone, savingRecord == nil, let onOfflineRecord else { return }
        savingRecord = frame
        Task {
            let saved = await onOfflineRecord(record)
            // 存的时候断开了就不确认，秤下次还会再发。
            // 没存成功也不确认；这次连接不再重试，记录留在秤里。
            guard saved, savingRecord == frame, self.peripheral === peripheral else { return }
            savingRecord = nil
            send(ScaleCommand.historyAck, to: peripheral)
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
        writer = nil
        savingRecord = nil
        handshakeDone = false
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
