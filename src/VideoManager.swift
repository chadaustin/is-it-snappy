import Photos

typealias Token = Int

protocol VideoModel {
    var uniqueID: String { get }
    var creationDate: Date? { get }
}

class PHVideoModel: VideoModel {
    let asset: PHAsset
    
    var uniqueID: String {
        return asset.localIdentifier
    }
    
    var creationDate: Date? {
        return asset.creationDate
    }
    
    init(asset: PHAsset) {
        self.asset = asset
    }
}

class FakeVideoModel: VideoModel {
    var uniqueID: String
    var creationDate: Date?

    init(id: String, ctime: Date) {
        self.uniqueID = id
        self.creationDate = ctime
    }
}

extension Date {
    static func fromLocalTime(_ str: String) -> Date {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        df.timeZone = TimeZone.current
        return df.date(from: str)!
    }
}

final class VideoManager: NSObject, PHPhotoLibraryChangeObserver {
    static var shared = VideoManager()
    
    private var observers: [Token: () -> Void] = [:]
    private var currentToken = 0
    
    private(set) var allVideos: [VideoModel] = [] {
        didSet {
            precondition(Thread.isMainThread)
            recalculateGroups()
            for observer in observers.values {
                observer()
            }
        }
    }
    
    struct VideoGroup {
        var date: Date
        var videos: [VideoModel]
    }
    
    private(set) var groupedVideos: [VideoGroup] = []
    
    private func recalculateGroups() {
        precondition(Thread.isMainThread)
        let allVideos = self.allVideos.sorted { lhs, rhs in
            switch (lhs.creationDate, rhs.creationDate) {
            case (.none, .none): return false
            case (.none, .some): return true
            case (.some, .none): return false
            case (.some(let dateL), .some(let dateR)):
                switch dateL.compare(dateR) {
                case .orderedAscending: return false
                case .orderedSame: return false
                case .orderedDescending: return true
                }
            }
        }
        
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        groupedVideos = []

        var currentGroup: VideoGroup?
        
        func onSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
            // TODO: calculate day with local timezone
            let componentsL = calendar.dateComponents([.year, .day], from: lhs)
            let componentsR = calendar.dateComponents([.year, .day], from: rhs)
            let yearL = componentsL.year!
            let dayL = componentsL.day!
            let yearR = componentsR.year!
            let dayR = componentsR.day!
            Swift.print("\(yearL),\(dayL) == \(yearR),\(dayR)")
            return yearL == yearR && dayL == dayR
        }
        
        func flush() {
            if let cg = currentGroup {
                groupedVideos.append(cg)
            }
            currentGroup = nil
        }
        
        for video in allVideos {
            guard let creationDate = video.creationDate else {
                continue
            }
            if let cg = currentGroup,
                onSameDay(cg.date, creationDate) {
                currentGroup?.videos.append(video)
            } else {
                flush()
                currentGroup = VideoGroup(date: creationDate, videos: [video])
            }
        }
        
        flush()
    }
    
    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
        
        VideoManager.getExistingVideos { videos in
            self.allVideos = videos
        }
    }
    
    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }
    
    func register(observer: @escaping () -> Void) -> Token {
        precondition(Thread.isMainThread)
        currentToken += 1
        let token = currentToken
        observers[token] = observer
        return token
    }
    
    func unregister(token: Token) {
        precondition(Thread.isMainThread)
        precondition(observers[token] != nil)
        observers[token] = nil
    }
    
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async {
            // TODO: implement state machine -- if in the middle of a request, kick off a new one when this one finishes
            // or: ignore result from old one
            VideoManager.getExistingVideos { videos in
                self.allVideos = videos
            }
        }
    }

    static func getAlbum(handler: @escaping (PHAssetCollection) -> ()) {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", appName)
        let collection = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
        //Check return value - If found, then get the first album out
        if let _: AnyObject = collection.firstObject {
            handler(collection.firstObject!)
        } else {
            var assetCollectionPlaceholder: PHObjectPlaceholder!
            //If not found - Then create a new album
            PHPhotoLibrary.shared().performChanges({
                let createAlbumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: appName)
                assetCollectionPlaceholder = createAlbumRequest.placeholderForCreatedAssetCollection
            }, completionHandler: { success, error in
                if success {
                    let collectionFetchResult = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [assetCollectionPlaceholder.localIdentifier], options: nil)
                    DispatchQueue.main.async {
                        handler(collectionFetchResult.firstObject!)
                    }
                } else {
                    // some kind of error
                }
            })
        }
    }

    static func getExistingVideos(handler: @escaping ([VideoModel]) -> Void) {
        if !screenshotMode {
            getAlbum { assetCollection in
                let assets = PHAsset.fetchAssets(in: assetCollection, options: nil)

                var output: [VideoModel] = []
                assets.enumerateObjects({
                    (object: AnyObject!, count: Int, stop: UnsafeMutablePointer<ObjCBool>) in
                    
                    if let asset = object as? PHAsset {
                        let model = PHVideoModel(asset: asset)
                        output.append(model)
                    }
                })

                handler(output)
            }
        } else {
            DispatchQueue.main.async {
                let fakeModels = [
                    FakeVideoModel(id: "fvm1", ctime: Date.fromLocalTime("2017-03-22 10:35:22")),
                    FakeVideoModel(id: "fvm2", ctime: Date.fromLocalTime("2017-03-22 10:38:46")),
                    FakeVideoModel(id: "fvm3", ctime: Date.fromLocalTime("2017-03-25 18:45:37")),
                    FakeVideoModel(id: "fvm4", ctime: Date.fromLocalTime("2017-03-25 19:16:43")),
                ]
                handler(fakeModels)
            }
        }
    }
}
