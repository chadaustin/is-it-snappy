import Foundation

struct Mark {
    var name: String?
    var input: Double?
    var output: Double?
    
    func displayLabel(_ defaultName: String? = nil) -> String {
        let elapsed: String?
        if let input = input, let output = output {
            elapsed = String(format: "%.1f", (output - input) * 1000)
        } else {
            elapsed = nil
        }
        
        switch (name ?? defaultName, elapsed) {
        case let (.some(name), .some(elapsed)): return "\(name) -- \(elapsed) ms"
        case let (.some(name), .none): return "\(name) --"
        case let (.none, .some(elapsed)): return "-- \(elapsed) ms"
        case (.none, .none): return "--"
        }
    }

    func encode() -> Any {
        var object: [String: Any] = [:]
        object["name"] = name
        object["input"] = input
        object["output"] = output
        return object
    }

    static func decode(_ record: Any) -> Mark? {
        guard let object = record as? [String: Any] else {
            return nil
        }

        let name = object["name"] as? String
        let input = object["input"] as? Double
        let output = object["output"] as? Double
        return Mark(name: name, input: input, output: output)
    }
}

class MarkDatabase {
    var marks: [String: Mark] = [:]

    init() {
        marks = MarkDatabase.load()
    }

    func set(localIdentifier: String, mark: Mark) {
        marks[localIdentifier] = mark
        save()
    }
    
    func setName(localIdentifier: String, name: String) {
        if var mark = marks[localIdentifier] {
            mark.name = name
            marks[localIdentifier] = mark
        } else {
            marks[localIdentifier] = Mark(
                name: name,
                input: nil,
                output: nil)
        }
        save()
    }
    
    func setInputTime(localIdentifier: String, input: Double) {
        if var mark = marks[localIdentifier] {
            mark.input = input
            marks[localIdentifier] = mark
        } else {
            marks[localIdentifier] = Mark(
                name: nil,
                input: input,
                output: nil)
        }
        save()
    }
    
    func setOutputTime(localIdentifier: String, output: Double) {
        if var mark = marks[localIdentifier] {
            mark.output = output
            marks[localIdentifier] = mark
        } else {
            marks[localIdentifier] = Mark(
                name: nil,
                input: nil,
                output: output)
        }
        save()
    }
    
    func get(localIdentifier: String) -> Mark? {
        return marks[localIdentifier]
    }

    func save() {
        var marksJSON: [String: Any] = [:]
        for (url, mark) in marks {
            marksJSON[url] = mark.encode()
        }
        let root: [String: Any] = ["marks": marksJSON]
        let data = try! JSONSerialization.data(withJSONObject: root, options: .prettyPrinted)
        FileManager.default.createFile(atPath: MarkDatabase.location, contents: data, attributes: nil)
    }

    static let shared = MarkDatabase()

    static var location: String {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        return NSString.path(withComponents: [documentsPath, "snappy-database.json"])
    }

    static func load() -> [String: Mark] {
        guard let data = FileManager.default.contents(atPath: MarkDatabase.location) else {
            return [:]
        }
        
        do {
            guard let root = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
                NSLog("Database JSON root is not an object")
                return [:]
            }
            guard let marks = root["marks"] as? [String: Any] else {
                NSLog("No marks key in root or marks not an array")
                return [:]
            }
            var result: [String: Mark] = [:]
            for (key, value) in marks {
                if let mark = Mark.decode(value) {
                    result[key] = mark
                }
            }
            return result
        }
        catch let error {
            NSLog("Error parsing database JSON: %s", "\(error)")
            return [:]
        }
    }
}
