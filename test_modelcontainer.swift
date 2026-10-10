import SwiftData
let schema = Schema([])
let config = ModelConfiguration(schema: schema)
let container = try! ModelContainer(for: schema, configurations: [config])
