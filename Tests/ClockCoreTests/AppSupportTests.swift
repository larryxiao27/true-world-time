import Foundation
import ServiceManagement
import Testing
@testable import AppSupport

@MainActor private final class FakeLoginService: LoginItemServicing {
    var status: SMAppService.Status = .notRegistered
    var nextStatus: SMAppService.Status = .enabled
    var shouldFail = false
    var registrations = 0
    var removals = 0
    var settingsOpened = 0
    func register() throws {
        registrations += 1
        if shouldFail { throw NSError(domain: "TestLogin", code: 1) }
        status = nextStatus
    }
    func unregister() async throws {
        removals += 1
        if shouldFail { throw NSError(domain: "TestLogin", code: 2) }
        status = .notRegistered
    }
    func openSettings() { settingsOpened += 1 }
}

@MainActor @Test func loginSettingDoesNotRegisterUntilExplicitlyEnabled() async {
    let service = FakeLoginService()
    let control = LoginItemController(service: service)
    control.refresh()
    #expect(service.registrations == 0)
    #expect(!control.requested)
    await control.setEnabled(true)
    #expect(service.registrations == 1)
    #expect(control.status == .enabled)
    #expect(control.requested)
    #expect(!control.busy)
    await control.setEnabled(false)
    #expect(service.removals == 1)
    #expect(!control.requested)
}

@MainActor @Test func pendingLoginApprovalIsNotReportedAsEnabled() async {
    let service = FakeLoginService(); service.nextStatus = .requiresApproval
    let control = LoginItemController(service: service)
    await control.setEnabled(true)
    #expect(control.requested)
    #expect(control.status == .requiresApproval)
    #expect(control.statusText.contains("尚未生效"))
    #expect(service.settingsOpened == 0)
    control.openSettings()
    #expect(service.settingsOpened == 1)
}

@MainActor @Test func loginRegistrationFailureRestoresActualState() async {
    let service = FakeLoginService(); service.shouldFail = true
    let control = LoginItemController(service: service)
    await control.setEnabled(true)
    #expect(!control.requested)
    #expect(control.errorMessage != nil)
    #expect(!control.busy)
}

@MainActor @Test func failedLoginRemovalStillShowsEnabled() async {
    let service = FakeLoginService(); service.status = .enabled; service.shouldFail = true
    let control = LoginItemController(service: service)
    control.refresh()
    await control.setEnabled(false)
    #expect(control.requested)
    #expect(control.status == .enabled)
    #expect(control.errorMessage != nil)
    #expect(!control.busy)
}

@Test func cpuCounterDeltasHandleIdleAndWraparound() {
    let initial = CPUCounters(user: 10, system: 10, idle: 50, nice: 0)
    let updated = CPUCounters(user: 20, system: 20, idle: 110, nice: 0)
    #expect(updated.percent(since: initial) == 25)
    #expect(initial.percent(since: initial) == nil)
    let beforeWrap = CPUCounters(user: UInt32.max - 6, system: 0, idle: 10, nice: 0)
    let afterWrap = CPUCounters(user: 3, system: 0, idle: 20, nice: 0)
    #expect(afterWrap.percent(since: beforeWrap) == 50)
}

private final class FakeResourceReader: ResourceReading {
    var count = 0
    func sample() -> ResourceSnapshot {
        count += 1
        return ResourceSnapshot(systemCPUPercent: 12, appCPUPercent: 0.1, appMemoryBytes: 1234)
    }
}

@Test func resourceMonitorNeverPollsHiddenAndReleasesItsReader() {
    var creations = 0
    weak var reader: FakeResourceReader?
    let monitor = VisibleResourceMonitor {
        creations += 1
        let value = FakeResourceReader(); reader = value
        return value
    }
    #expect(monitor.sampleIfDue(at: 0) == nil)
    #expect(creations == 0)
    monitor.setVisible(true)
    #expect(monitor.sampleIfDue(at: 0) != nil)
    #expect(monitor.sampleIfDue(at: 1) == nil)
    #expect(monitor.sampleIfDue(at: 2) != nil)
    #expect(reader?.count == 2)
    monitor.setVisible(false)
    #expect(reader == nil)
    #expect(monitor.sampleIfDue(at: 100) == nil)
    #expect(creations == 1)
    monitor.setVisible(true)
    #expect(monitor.sampleIfDue(at: 100) != nil)
    #expect(creations == 2)
}
