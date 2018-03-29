// ===================================================================================================
// Copyright (C) 2017 Kaltura Inc.
//
// Licensed under the AGPLv3 license, unless a different license for a 
// particular library is specified in the applicable library path.
//
// You may obtain a copy of the License at
// https://www.gnu.org/licenses/agpl-3.0.html
// ===================================================================================================

import Foundation
import AVFoundation

/// Manage local (downloaded) assets.
@objc public class LocalAssetsManager: NSObject {
    let storage: LocalDataStore
    var delegates = Set<FPSAssetLoaderDelegate>()
    
    private override init() {
        fatalError("Private initializer, use one of the factory methods")
    }
    
    /**
     Create a new LocalAssetsManager for DRM-protected content. 
     Uses the default data-store.
     */
    @objc public static func managerWithDefaultDataStore() -> LocalAssetsManager {
        return LocalAssetsManager(storage: DefaultLocalDataStore.defaultDataStore())
    }
    
    /**
     Create a new LocalAssetsManager for DRM-protected content.
     
     - Parameter storage: data store. 
     */
    @objc public static func manager(storage: LocalDataStore) -> LocalAssetsManager {
        return LocalAssetsManager(storage: storage)
    }
    
    /**
     Create a new LocalAssetsManager for non-DRM content.
     */
    @objc public static func manager() -> LocalAssetsManager {
        return LocalAssetsManager(storage: nil)
    }
    
    /**
     Create a new LocalAssetsManager.
     
     - Parameter storage: data store. Used for DRM data, and may only be nil if DRM is not used.
     */
    private init(storage: LocalDataStore?) {
        self.storage = storage ?? NullStore.instance
    }
    
    /// Create a PKMediaSource for a local asset. This allows the player to play a downloaded asset.
    private func createLocalMediaSource(for assetId: String, localURL: URL) -> PKMediaSource {
        return LocalMediaSource(storage: self.storage, id: assetId, localContentUrl: localURL)
    }
    
    /// Create a PKMediaEntry for a local asset. This is a convenience function that wraps the result of
    /// `createLocalMediaSource(for:localURL:)` with a PKMediaEntry.
    @objc public func createLocalMediaEntry(for assetId: String, localURL: URL) -> PKMediaEntry {
        let mediaSource = createLocalMediaSource(for: assetId, localURL: localURL)
        return PKMediaEntry.init(assetId, sources: [mediaSource])
    }
    
    /// Get the preferred PKMediaSource for download purposes. This function takes into account
    /// the capabilities of the device.
    @objc public func getPreferredDownloadableMediaSource(for mediaEntry: PKMediaEntry) -> PKMediaSource? {
        
        guard let sources = mediaEntry.sources else {
            PKLog.error("no media sources in mediaEntry!")
            return nil
        }
        
        // On iOS 10 and up: HLS (clear or FP), MP4, WVM
        // Below iOS10: HLS (only clear), MP4, WVM
        if DRMSupport.fairplayOffline {
            if let source = sources.first(where: {$0.mediaFormat == .hls}) {
                return source
            }
        } else {
            if let source = sources.first(where: {$0.mediaFormat == .hls && ($0.drmData == nil || $0.drmData!.isEmpty)}) {
                return source
            }
        }
        
        if let source = sources.first(where: {$0.mediaFormat == .mp4}) {
            return source
        }
        
        if DRMSupport.widevineClassic, let source = sources.first(where: {$0.mediaFormat == .wvm}) {
            return source
        }
        
        PKLog.error("no downloadable media sources!")
        return nil
    }
    
    @objc public func registerDownloadedAsset(location: URL, mediaSource: PKMediaSource, callback: @escaping (Error?) -> Void) {
        if mediaSource.mediaFormat == .hls && mediaSource.drmData?.first?.scheme == DRMParams.Scheme.fairplay {
            if #available(iOS 10.3, *) {
                FPSContentKeyManager.shared.installFairPlayOfflineLicense(for: location, mediaSource: mediaSource, dataStore: storage, done: callback)
            } else {
                // TODO Fallback on earlier versions
            }
            
        } else if mediaSource.mediaFormat == .wvm {
            // Widevine Classic
            WidevineClassicHelper.registerLocalAsset(location.absoluteString, mediaSource: mediaSource, refresh:false, callback: callback)
        }
    }
    
    /// Notifies the SDK that downloading of an asset has finished.
    @available(*, deprecated)
    @objc public func assetDownloadFinished(location: URL, mediaSource: PKMediaSource, callback: @escaping (Error?) -> Void) {
        registerDownloadedAsset(location: location, mediaSource: mediaSource, callback: callback)
    }
    
    /// Renew Downloaded Asset
    @objc public func renewDownloadedAsset(location: URL, mediaSource: PKMediaSource, callback: @escaping (Error?) -> Void) {
        // FairPlay -- nothing to do
        
        // Widevine
        if mediaSource.mediaFormat == .wvm {
            WidevineClassicHelper.registerLocalAsset(location.absoluteString, mediaSource: mediaSource, refresh:true, callback: callback)
        }
    }
    
    @objc public func unregisterAsset(_ assetUri: String!, callback: @escaping (Error?) -> Void) {
        // TODO FairPlay
        
        // Widevine
        if assetUri.hasSuffix(".wvm") {
            WidevineClassicHelper.unregisterAsset(assetUri, callback: callback)
        }
    }
}

// For AVAssetDownloadTask
extension LocalAssetsManager {
    
    /**
     Prepare an AVURLAsset for download via AVAssetDownloadTask.
     Note that this is only relevant for FairPlay assets, and does not do anything otherwise.
     
     - Parameters:
     - asset: an AVURLAsset, ready to be downloaded
     - mediaSource: the original source for the asset. mediaSource.contentUrl and asset.url should point at the same file.
     */
    @objc public func prepareForDownload(asset: AVURLAsset, mediaSource: PKMediaSource) {
        
        // This function is a noop if no DRM data or DRM is not FairPlay.
        guard let drmData = mediaSource.drmData?.first as? FairPlayDRMParams else {return}
        
        PKLog.debug("Preparing asset for download; asset.url:", asset.url)
        
        guard #available(iOS 10, *), DRMSupport.fairplayOffline else {
            PKLog.error("Downloading FairPlay content is not supported on device")
            return
        }
        
        let resourceLoaderDelegate = FPSAssetLoaderDelegate.configureDownload(asset: asset, drmData: drmData, storage: storage)
        
        self.delegates.update(with: resourceLoaderDelegate)
        
        resourceLoaderDelegate.done =  { (_ error: Error?)->Void in
            self.delegates.remove(resourceLoaderDelegate);
        }
    }
    
    /// Prepare a PKMediaEntry for download using AVAssetDownloadTask.
    public func prepareForDownload(of mediaEntry: PKMediaEntry) -> (AVURLAsset, PKMediaSource)? {
        guard let source = getPreferredDownloadableMediaSource(for: mediaEntry) else { return nil }
        guard let url = source.contentUrl else { return nil }
        let avAsset = AVURLAsset(url: url)
        prepareForDownload(asset: avAsset, mediaSource: source)
        return (avAsset, source)
    }
}

fileprivate class NullStore: LocalDataStore {
    func exists(key: String) -> Bool {
        PKLog.error("LocalDataStore not set")
        return false
    }
    
    public func remove(key: String) throws {
        PKLog.error("LocalDataStore not set")
    }
    
    @objc public func load(key: String) throws -> Data {
        PKLog.error("LocalDataStore not set")
        throw NSError.init(domain: "LocalAssetsManager", code: -1, userInfo: nil)
    }
    
    @objc public func save(key: String, value: Data) throws {
        PKLog.error("LocalDataStore not set")
    }
    
    static let instance = NullStore()
}


class LocalMediaSource: PKMediaSource {
    let storage: LocalDataStore
    
    init(storage: LocalDataStore, id: String, localContentUrl: URL) {
        self.storage = storage
        super.init(id, contentUrl: localContentUrl)
    }
}
