import Foundation
import CoreBluetooth
import Combine

// Nordic UART Service (NUS) — the standard BLE serial profile used by most
// OnStep Bluetooth adapters (HC-05, HM-10, etc. usually re-expose as NUS).
// iOS writes to the TX characteristic and receives on the RX characteristic.
private let nusServiceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
private let nusTXCharUUID  = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // iOS writes here
private let nusRXCharUUID  = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // iOS receives here

// Manages BLE scanning, connecting, and raw data transfer.
// UI layers call startScanning() to discover peripherals, then connect(to:)
// to pick one. After that, makeTransport() hands an OnStepTransport to
// OnStepManager so it can send/receive LX200 commands over BLE.
final class BluetoothManager: NSObject, ObservableObject {
    @Published var discoveredDevices: [CBPeripheral] = []
    @Published var isScanning   = false
    @Published var isConnected  = false

    private var centralManager: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var receiveHandler: ((Data) -> Void)?

    override init() {
        super.init()
        // Run CoreBluetooth on a background utility queue to keep the main thread free.
        centralManager = CBCentralManager(delegate: self, queue: .global(qos: .utility))
    }

    var isBluetoothReady: Bool { centralManager.state == .poweredOn }

    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        DispatchQueue.main.async { self.discoveredDevices.removeAll() }
        DispatchQueue.main.async { self.isScanning = true }
        // Scan all peripherals; unnamed ones are filtered out in the delegate.
        centralManager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScanning() {
        centralManager.stopScan()
        DispatchQueue.main.async { self.isScanning = false }
    }

    func connect(to peripheral: CBPeripheral) {
        stopScanning()
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        if let p = connectedPeripheral { centralManager.cancelPeripheralConnection(p) }
    }

    // Creates a transport object that wraps this manager for use by OnStepManager.
    func makeTransport() -> BluetoothTransport {
        BluetoothTransport(manager: self)
    }

    // Sends raw bytes to the connected peripheral, splitting into MTU-sized chunks
    // if the payload is larger than the BLE packet size.
    fileprivate func send(_ data: Data) {
        guard let peripheral = connectedPeripheral, let char = txCharacteristic else { return }
        let mtu = peripheral.maximumWriteValueLength(for: .withoutResponse)
        var offset = 0
        while offset < data.count {
            let end = min(offset + mtu, data.count)
            peripheral.writeValue(data[offset..<end], for: char, type: .withoutResponse)
            offset = end
        }
    }

    fileprivate func setReceiveHandler(_ handler: @escaping (Data) -> Void) {
        receiveHandler = handler
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {}

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Accept devices that have a name in either the peripheral object OR the
        // advertisement data. Some ESP32 BLE builds put the name only in the scan
        // response, so peripheral.name can be nil even for named devices.
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard peripheral.name != nil || advertisedName != nil else { return }
        DispatchQueue.main.async {
            if !self.discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
                self.discoveredDevices.append(peripheral)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        peripheral.delegate = self
        // Discover only the NUS service to avoid unnecessary service discovery time.
        peripheral.discoverServices([nusServiceUUID])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        DispatchQueue.main.async {
            self.isConnected = false
            self.connectedPeripheral = nil
            self.txCharacteristic = nil
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        DispatchQueue.main.async { self.isConnected = false }
    }
}

// MARK: - CBPeripheralDelegate

extension BluetoothManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        peripheral.services?
            .filter { $0.uuid == nusServiceUUID }
            .forEach { peripheral.discoverCharacteristics([nusTXCharUUID, nusRXCharUUID], for: $0) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        service.characteristics?.forEach { char in
            if char.uuid == nusTXCharUUID {
                txCharacteristic = char          // store for outgoing writes
            } else if char.uuid == nusRXCharUUID {
                peripheral.setNotifyValue(true, for: char)  // subscribe for incoming data
            }
        }
        // Only mark connected once we have the TX characteristic — can't send without it.
        if txCharacteristic != nil {
            DispatchQueue.main.async { self.isConnected = true }
        }
    }

    // Called whenever the mount sends data back over BLE.
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == nusRXCharUUID, let data = characteristic.value else { return }
        receiveHandler?(data)
    }
}

// MARK: - BluetoothTransport

// Adapts BluetoothManager to the OnStepTransport protocol so OnStepManager
// can send LX200 commands without knowing it's talking over BLE.
final class BluetoothTransport: OnStepTransport {
    private weak var manager: BluetoothManager?
    var isConnected: Bool { manager?.isConnected ?? false }

    init(manager: BluetoothManager) { self.manager = manager }

    func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        manager?.send(data)
        completion(nil)   // BLE withoutResponse writes don't provide delivery confirmation
    }

    func startReceiving(handler: @escaping (Data) -> Void) {
        manager?.setReceiveHandler(handler)
    }

    func disconnect() { manager?.disconnect() }
}
