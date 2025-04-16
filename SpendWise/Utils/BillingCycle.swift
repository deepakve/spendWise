import Foundation

class BillingCycle {
    static let cycleStartDay = 17
    
    static func currentCycle() -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let now = Date()
        
        // Get the current month's cycle start date
        var components = calendar.dateComponents([.year, .month], from: now)
        components.day = cycleStartDay
        
        guard let cycleStart = calendar.date(from: components) else {
            return (now, now)
        }
        
        // If we're before the cycle start, use previous month's cycle
        if now < cycleStart {
            components.month = components.month! - 1
            guard let previousCycleStart = calendar.date(from: components) else {
                return (now, now)
            }
            
            components.month = components.month! + 1
            components.day = cycleStartDay - 1
            guard let cycleEnd = calendar.date(from: components) else {
                return (now, now)
            }
            
            return (previousCycleStart, cycleEnd)
        }
        
        // If we're after the cycle start, use current month's cycle
        components.month = components.month! + 1
        components.day = cycleStartDay - 1
        guard let cycleEnd = calendar.date(from: components) else {
            return (now, now)
        }
        
        return (cycleStart, cycleEnd)
    }
    
    static func nextCycle() -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let now = Date()
        
        var components = calendar.dateComponents([.year, .month], from: now)
        components.day = cycleStartDay
        
        // If we're before the cycle start, use current month's cycle
        if now < calendar.date(from: components)! {
            components.month = components.month! + 1
            guard let cycleStart = calendar.date(from: components) else {
                return (now, now)
            }
            
            components.month = components.month! + 1
            components.day = cycleStartDay - 1
            guard let cycleEnd = calendar.date(from: components) else {
                return (now, now)
            }
            
            return (cycleStart, cycleEnd)
        }
        
        // If we're after the cycle start, use next month's cycle
        components.month = components.month! + 2
        components.day = cycleStartDay - 1
        guard let cycleEnd = calendar.date(from: components) else {
            return (now, now)
        }
        
        components.day = cycleStartDay
        guard let cycleStart = calendar.date(from: components) else {
            return (now, now)
        }
        
        return (cycleStart, cycleEnd)
    }
    
    static func formatCycle(_ cycle: (start: Date, end: Date)) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return "\(formatter.string(from: cycle.start)) - \(formatter.string(from: cycle.end))"
    }
} 