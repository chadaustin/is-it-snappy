import Foundation

struct Mark {
    var name: String
    var input: Double
    var output: Double

    func encode() -> Any {
        var object: [String: Any] = [:]
        object["name"] = name
        object["input"] = input
        object["output"] = output
        return object
    }

    static func decode(_ record: Any) -> Mark? {
        if let object = record as? [String: Any] {
            if
                let name = object["name"] as? String,
                let input = object["input"] as? Double,
                let output = object["output"] as? Double
            {
                return Mark(name: name, input: input, output: output)
            } else {
                return nil
            }
        } else {
            return nil
        }
    }
}

class MarkDatabase {
    var marks: [String: Mark] = [:]

    init() {
        marks = MarkDatabase.load()
    }

    func set(url: String, mark: Mark) {
        marks[url] = mark
    }

    func get(url: String) -> Mark? {
        return marks[url]
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

        if let data = FileManager.default.contents(atPath: MarkDatabase.location) {
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
        } else {
            return [:]
        }
    }
}
