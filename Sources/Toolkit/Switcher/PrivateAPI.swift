import ApplicationServices

// Undocumented calls the window switcher depends on. The public APIs can only
// see windows on the current Space and can only bring a whole app forward.

/// The window server ID behind an accessibility window element.
@_silgen_name("_AXUIElementGetWindow") @discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ window: inout CGWindowID) -> AXError

/// Builds an accessibility element from its raw token, which is how windows
/// on other Spaces are reached.
@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

@_silgen_name("GetProcessForPID") @discardableResult
func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

/// Brings one window of a process forward, rather than all of them.
@_silgen_name("_SLPSSetFrontProcessWithOptions") @discardableResult
func _SLPSSetFrontProcessWithOptions(_ psn: inout ProcessSerialNumber, _ window: CGWindowID, _ mode: UInt32) -> CGError

@_silgen_name("SLPSPostEventRecordTo") @discardableResult
func SLPSPostEventRecordTo(_ psn: inout ProcessSerialNumber, _ bytes: UnsafeMutablePointer<UInt8>) -> CGError

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32

/// One dictionary per display, each listing its Spaces.
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray

@_silgen_name("CGSCopyWindowsWithOptionsAndTags")
func CGSCopyWindowsWithOptionsAndTags(_ connection: Int32, _ owner: Int, _ spaces: CFArray, _ options: Int,
                                      _ setTags: inout Int, _ clearTags: inout Int) -> CFArray

/// Turns a system shortcut on or off. 1 is Cmd-Tab, 2 is Cmd-Shift-Tab.
@_silgen_name("CGSSetSymbolicHotKeyEnabled") @discardableResult
func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ enabled: Bool) -> CGError
