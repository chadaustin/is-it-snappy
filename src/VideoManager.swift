import Photos

// TODO: switch to a uuid / local identifier
let appName: String = Bundle.main.infoDictionary?["CFBundleDisplayName"]! as! String

typealias Token = Int

class VideoManager: NSObject, PHPhotoLibraryChangeObserver {
    static var shared = VideoManager()
    
    var observers: [Token: () -> Void] = [:]
    var currentToken = 0
    var videos: [VideoModel] = [] {
        didSet {
            for observer in observers.values {
                observer()
            }
        }
    }
    
    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
        
        VideoManager.getExistingVideos { videos in
            self.videos = videos
        }
    }
    
    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }
    
    func register(observer: @escaping () -> Void) -> Token {
        currentToken += 1
        let token = currentToken
        observers[token] = observer
        return token
    }
    
    func unregister(token: Token) {
        precondition(observers[token] != nil)
        observers[token] = nil
    }
    
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        // TODO: implement state machine -- if in the middle of a request, kick off a new one when this one finishes
        // or: ignore result from old one
        VideoManager.getExistingVideos { videos in
            self.videos = videos
        }
    }

    static func getAlbum(handler: @escaping (PHAssetCollection) -> ()) {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", appName)
        let collection : PHFetchResult = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
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
                    print(collectionFetchResult)
                    handler(collectionFetchResult.firstObject!)
                } else {
                    // some kind of error
                }
            })
        }
    }

    static func getExistingVideos(handler: @escaping ([VideoModel]) -> Void) {
        getAlbum { assetCollection in
            let assets = PHAsset.fetchAssets(in: assetCollection, options: nil)

            var output: [VideoModel] = []
            assets.enumerateObjects({
                (object: AnyObject!, count: Int, stop: UnsafeMutablePointer<ObjCBool>) in
                
                if let asset = object as? PHAsset {
                    let model = VideoModel(asset: asset)
                    output.append(model)
                }
            })

            handler(output)
        }

        /*
        let imageManager = PHCachingImageManager()
        //Enumerating objects to get a chached image - This is to save loading time
        let imageSize = CGSize(width: asset.pixelWidth, height: asset.pixelHeight)

        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        imageManager.requestImage(for: asset, targetSize: imageSize, contentMode: .aspectFill, options: options, resultHandler: {(image: UIImage?,
        info: [AnyHashable: Any]?) in
        print(info)
        print(image)
        })
        */
    }
}
