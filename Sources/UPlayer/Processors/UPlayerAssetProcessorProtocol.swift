//
//  UPlayerAssetProcessorProtocol.swift
//  UPlayer
//
//  Created by Max Komleu on 2/23/26.
//

import Combine
import Foundation

private let logScope = "[proccessing queue]"

public typealias UPlayerAssetProcessingID = UUID

public protocol UPlayerAssetProcessorProtocol: AnyObject {
    
    var id: String { get }
    
    init(id: String)
    
    var isRunning: Bool { get }
    
    func process(asset: UPlayerAssetProtocol) -> AnyPublisher<UPlayerAssetProtocol, Error>
    func cancel()
    
    func makeProcessor() -> UPlayerAssetProcessorProtocol
}

public protocol UPlayerAssetProcessorsQueueDelegate: AnyObject {
    func didStartProcessing(source: UPlayerAssetProcessorsQueueProtocol)
    func didFinishProcessing(source: UPlayerAssetProcessorsQueueProtocol, error: Error?)
    func didFinishProcessing(source: UPlayerAssetProcessorsQueueProtocol, asset: UPlayerAssetProtocol)
}

public protocol UPlayerAssetProcessorsQueueProtocol: AnyObject {

    var isRunning: Bool { get }

    var delegate: UPlayerAssetProcessorsQueueDelegate? { get set }

    @discardableResult
    func start(asset: UPlayerAssetProtocol) -> UPlayerAssetProcessingID

    func stop()
    func stop(id: UPlayerAssetProcessingID)

    func add(processor: UPlayerAssetProcessorProtocol)
    func remove(processor: UPlayerAssetProcessorProtocol)
}

private final class ProcessingSession {

    let id: UPlayerAssetProcessingID
    let asset: UPlayerAssetProtocol
    let processors: [UPlayerAssetProcessorProtocol]

    var cancellable: AnyCancellable?

    init(id: UPlayerAssetProcessingID,
         asset: UPlayerAssetProtocol,
         processors: [UPlayerAssetProcessorProtocol]) {
        self.id = id
        self.asset = asset
        self.processors = processors
    }

    func cancel() {
        processors.forEach {
            $0.cancel()
        }

        cancellable?.cancel()
        cancellable = nil
    }
}

public final class UPlayerAssetProcessorsQueue: UPlayerAssetProcessorsQueueProtocol {

    // MARK: Fields
    
    private var processorTemplates: [UPlayerAssetProcessorProtocol] = []
    private var sessions: [UPlayerAssetProcessingID: ProcessingSession] = [:]

    private let lock = NSLock()

    // MARK: Constructors/Destructor
    
    public init() {}

    // MARK: UPlayerAssetProcessorsQueueProtocol
    
    public weak var delegate: UPlayerAssetProcessorsQueueDelegate?

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }

        return !sessions.isEmpty
    }

    @discardableResult
    public func start(asset: UPlayerAssetProtocol) -> UPlayerAssetProcessingID {

        let processingID = UUID()

        let processors = processorTemplates.map {
            $0.makeProcessor()
        }

        let session = ProcessingSession(
            id: processingID,
            asset: asset,
            processors: processors
        )

        lock.lock()
        sessions[processingID] = session
        lock.unlock()

        delegate?.didStartProcessing(source: self)

        log("\(logScope) started, id: \(processingID), asset: \(asset.url)", loggingLevel: .debug)

        let publisher = processors.reduce(
            Just(asset)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()) { chain, processor in

            chain
                .flatMap { asset -> AnyPublisher<UPlayerAssetProtocol, Error> in

                    log("\(logScope) processing: \(asset.url), processor: \(processor.id), id: \(processingID)", loggingLevel: .debug)

                    return processor.process(asset: asset)
                }
                .eraseToAnyPublisher()
        }

        session.cancellable = publisher.sink(receiveCompletion: { [weak self] completion in
                guard let self else { return }

                switch completion {

                case .finished:
                    log("\(logScope) succeed, id: \(processingID), asset: \(asset.url)", loggingLevel: .debug)

                case .failure(let error):
                    log("\(logScope) failed, id: \(processingID), asset: \(asset.url), error: \(error)", loggingLevel: .error)

                    self.delegate?.didFinishProcessing(source: self, error: error)
                }

                self.removeSession(id: processingID)
            },

            receiveValue: { [weak self] finalAsset in
                guard let self else { return }

                log("\(logScope) end, id: \(processingID), asset: \(finalAsset.url)", loggingLevel: .debug)

                self.delegate?.didFinishProcessing(source: self, asset: finalAsset)
            }
        )

        return processingID
    }

    public func stop(id: UPlayerAssetProcessingID) {

        lock.lock()
        let session = sessions[id]
        lock.unlock()

        session?.cancel()

        removeSession(id: id)
    }

    public func stop() {

        lock.lock()
        let allSessions = Array(sessions.values)
        sessions.removeAll()
        lock.unlock()

        allSessions.forEach {
            $0.cancel()
        }
    }

    public func add(processor: UPlayerAssetProcessorProtocol) {
        let contains = processorTemplates.contains {
            $0.id == processor.id
        }

        guard !contains else {
            return
        }

        processorTemplates.append(processor)
    }

    public func remove(processor: UPlayerAssetProcessorProtocol) {
        processorTemplates.removeAll {
            $0.id == processor.id
        }
    }
    
    // MARK: Helpers

    private func removeSession(id: UPlayerAssetProcessingID) {
        lock.lock()
        sessions.removeValue(forKey: id)
        lock.unlock()
    }
}
