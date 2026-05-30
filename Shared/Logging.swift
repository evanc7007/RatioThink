import os

enum Log {
  static let app    = Logger(subsystem: "com.ratiothink.app", category: "app")
  static let helper = Logger(subsystem: "com.ratiothink.app.helper", category: "helper")
  static let xpc    = Logger(subsystem: "com.ratiothink.app", category: "xpc")
  static let engine = Logger(subsystem: "com.ratiothink.app", category: "engine")
  static let store  = Logger(subsystem: "com.ratiothink.app", category: "store")
}
