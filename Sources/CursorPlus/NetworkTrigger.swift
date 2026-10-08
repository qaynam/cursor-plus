import AppKit
import CoreLocation
import CoreWLAN
import Network

/// Watches which Wi-Fi network the Mac is on, so a session can start by itself on
/// the networks the user listed and end when the Mac leaves them.
///
/// macOS only hands the Wi-Fi name (SSID) to apps that hold Location access, so
/// this also owns that authorization. Without it `currentSSID` simply stays nil and
/// the trigger never fires.
///
/// Network changes arrive from `NWPathMonitor`; a slow poll backs it up, because
/// hopping between two Wi-Fi networks does not always produce a path update.
final class NetworkTrigger: NSObject, CLLocationManagerDelegate {

    /// Fired on the main thread when the SSID or the Location authorization changes.
    var onChange: (() -> Void)?

    private(set) var currentSSID: String?

    private let locationManager = CLLocationManager()
    private let pathMonitor = NWPathMonitor()
    private var pollTimer: Timer?

    override init() {
        super.init()
        locationManager.delegate = self
    }

    // MARK: Location access (needed to read the SSID)

    var locationAuthorized: Bool {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse: return true
        default: return false
        }
    }

    /// The user said no (or a profile forbids it); asking again shows nothing, so
    /// the only way forward is System Settings.
    var locationDenied: Bool {
        let status = locationManager.authorizationStatus
        return status == .denied || status == .restricted
    }

    /// Ask for Location access, or open its Settings pane when asking can no longer
    /// show a prompt.
    func requestLocationAccess() {
        if locationDenied {
            let pane = "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices"
            if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
        } else {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refresh()
        onChange?()
    }

    // MARK: Watching the network

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.aus.cursorplus.network"))

        let timer = Timer(timeInterval: 10, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        refresh()
    }

    /// Re-read the SSID; `onChange` fires only when it actually changed.
    func refresh() {
        let ssid = CWWiFiClient.shared().interface()?.ssid()
        guard ssid != currentSSID else { return }
        currentSSID = ssid
        onChange?()
    }
}
