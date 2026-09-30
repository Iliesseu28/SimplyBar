import Foundation
import IOKit.ps
import Testing

/// Power source and registry dictionaries shaped as macOS returns them (keys of `ioreg -rn AppleSmartBattery` and
/// of `IOPSGetPowerSourceDescription`). No MacBook was at hand: the laptop readings are covered by these fixtures only.
private enum Fixture {
    /// A MacBook at 87 %, charging, 312 cycles, 3 988 mAh of its 4 382 mAh design capacity.
    static var laptopSource: [String: Any] { [
        kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSIsPresentKey: true, kIOPSNameKey: "InternalBattery-0",
        kIOPSCurrentCapacityKey: 87, kIOPSMaxCapacityKey: 100, kIOPSIsChargingKey: true,
        kIOPSPowerSourceStateKey: kIOPSACPowerValue, kIOPSBatteryHealthKey: kIOPSGoodValue,
    ] }
    static var laptopRegistry: [String: Any] { [
        "BatteryInstalled": true, "CycleCount": 312, "DesignCapacity": 4_382, "NominalChargeCapacity": 3_988,
        "AppleRawMaxCapacity": 3_950,
    ] }
    /// The desktop Mac this was written on: no power source, and a registry entry full of zeros.
    static var desktopRegistry: [String: Any] { [
        "BatteryInstalled": false, "CycleCount": 0, "CurrentCapacity": 0, "MaxCapacity": 0, "ExternalConnected": true,
    ] }
    /// A Bluetooth accessory or a UPS: never the Mac's battery.
    static var accessory: [String: Any] { [
        kIOPSTypeKey: "Accessory Source", kIOPSIsPresentKey: true, kIOPSCurrentCapacityKey: 40, kIOPSMaxCapacityKey: 100,
    ] }
    static var ups: [String: Any] { [
        kIOPSTypeKey: kIOPSUPSType, kIOPSIsPresentKey: true, kIOPSCurrentCapacityKey: 90, kIOPSMaxCapacityKey: 100,
    ] }

    static func source(_ changes: [String: Any]) -> [String: Any] {
        laptopSource.merging(changes) { _, new in new }
    }
}

struct HealthTests {
    @Test func thermalStatesMapToLevels() {
        #expect(ThermalLevel(.nominal) == .nominal)
        #expect(ThermalLevel(.fair) == .fair)
        #expect(ThermalLevel(.serious) == .serious)
        #expect(ThermalLevel(.critical) == .critical)
        #expect(ThermalLevel.allCases.filter(\.isHot) == [.serious, .critical])
        #expect(ThermalLevel.nominal.advice == nil && ThermalLevel.fair.advice == nil)
        #expect(ThermalLevel.serious.advice != nil && ThermalLevel.critical.advice != nil)
    }

    @Test func laptopBatteryReadsEveryValue() throws {
        let battery = try #require(MacBatteryReader.battery(powerSources: [Fixture.laptopSource],
                                                            registry: Fixture.laptopRegistry))
        #expect(battery == MacBattery(charge: 87, isCharging: true, maximumCapacity: 91, cycleCount: 312, condition: .normal))
    }

    @Test func desktopMacHasNoBatteryEvenWithARegistryEntry() {
        #expect(MacBatteryReader.battery(powerSources: [], registry: Fixture.desktopRegistry) == nil)
        #expect(MacBatteryReader.battery(powerSources: [], registry: nil) == nil)
        #expect(MacBatteryReader.battery(powerSources: [Fixture.accessory, Fixture.ups], registry: nil) == nil)
        let absent = Fixture.source([kIOPSIsPresentKey: false])
        #expect(MacBatteryReader.battery(powerSources: [absent], registry: Fixture.laptopRegistry) == nil)
    }

    @Test func unreadableRegistryLeavesOnlyThePowerSourceValues() throws {
        let battery = try #require(MacBatteryReader.battery(powerSources: [Fixture.accessory, Fixture.laptopSource],
                                                            registry: nil))
        #expect(battery.charge == 87)
        #expect(battery.cycleCount == nil && battery.maximumCapacity == nil)
        // A registry that says no battery is installed adds nothing, not zeros.
        let zeros = try #require(MacBatteryReader.battery(powerSources: [Fixture.laptopSource],
                                                          registry: Fixture.desktopRegistry))
        #expect(zeros.cycleCount == nil && zeros.maximumCapacity == nil)
    }

    @Test func chargeAndChargingFollowThePowerSource() throws {
        let onBattery = Fixture.source([kIOPSCurrentCapacityKey: 1_203, kIOPSMaxCapacityKey: 4_010, kIOPSIsChargingKey: false,
                                        kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue])
        let battery = try #require(MacBatteryReader.battery(powerSources: [onBattery], registry: nil))
        #expect(battery.charge == 30)
        #expect(!battery.isCharging)
        let noMaximum = Fixture.source([kIOPSMaxCapacityKey: 0])
        #expect(MacBatteryReader.battery(powerSources: [noMaximum], registry: nil) == nil)
    }

    @Test func maximumCapacityPrefersTheNominalCapacityAndStopsAt100() {
        #expect(MacBatteryReader.maximumCapacity(Fixture.laptopRegistry) == 91)
        #expect(MacBatteryReader.maximumCapacity(["DesignCapacity": 4_000, "AppleRawMaxCapacity": 3_000]) == 75)
        #expect(MacBatteryReader.maximumCapacity(["DesignCapacity": 4_000, "NominalChargeCapacity": 0,
                                                  "AppleRawMaxCapacity": 3_600]) == 90)
        #expect(MacBatteryReader.maximumCapacity(["DesignCapacity": 4_000, "NominalChargeCapacity": 4_150]) == 100)
        #expect(MacBatteryReader.maximumCapacity(["DesignCapacity": 0, "NominalChargeCapacity": 3_000]) == nil)
        #expect(MacBatteryReader.maximumCapacity(["NominalChargeCapacity": 3_000]) == nil)
    }

    @Test func conditionFollowsWhatMacOSReports() {
        #expect(MacBatteryReader.condition(Fixture.laptopSource) == .normal)
        #expect(MacBatteryReader.condition(Fixture.source([kIOPSBatteryHealthKey: kIOPSPoorValue])) == .serviceRecommended)
        #expect(MacBatteryReader.condition(Fixture.source([kIOPSBatteryHealthKey: kIOPSFairValue])) == .serviceRecommended)
        #expect(MacBatteryReader.condition(Fixture.source([kIOPSBatteryHealthConditionKey: kIOPSCheckBatteryValue]))
            == .serviceRecommended)
        #expect(MacBatteryReader.condition([kIOPSTypeKey: kIOPSInternalBatteryType]) == nil)
    }

    @Test func payloadKeepsHealthAndToleratesItsAbsence() throws {
        let health = HealthSample(thermal: .serious,
                                  battery: MacBattery(charge: 87, isCharging: false, maximumCapacity: 91, cycleCount: 312))
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let decoded = try SharedStore.decode(SharedStore.encode(WidgetPayload(date: date, health: health)))
        #expect(decoded.health == health)
        // A desktop Mac: no battery key at all.
        let desktop = try SharedStore.decode(Data(#"{"date":1790000000,"health":{"thermal":"nominal"}}"#.utf8))
        #expect(desktop.health == HealthSample(thermal: .nominal, battery: nil))
        // An older app wrote no health; a newer one a level this version does not know.
        #expect(try SharedStore.decode(Data(#"{"date":1790000000}"#.utf8)).health == nil)
        #expect(try SharedStore.decode(Data(#"{"date":1790000000,"health":{"thermal":"melting"}}"#.utf8)).health == nil)
    }

    /// This Mac, through the real APIs: a level always comes back, and a battery only with a charge in range.
    @Test func realReadingIsConsistent() {
        let sample = HealthReader.read()
        #expect(ThermalLevel.allCases.contains(sample.thermal))
        if let battery = sample.battery {
            #expect((0...100).contains(battery.charge))
            #expect(battery.maximumCapacity.map { (1...100).contains($0) } ?? true)
        }
    }
}
