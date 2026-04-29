//
//  UPlayerAssetProcessorProtocol.swift
//  UPlayer
//
//  Created by Max Komleu on 2/23/26.
//

import Combine
import Foundation

private let logScope = "[proccessing queue]"

public protocol UPlayerAssetProcessorProtocol: AnyObject {

    var id: String { get }

    init(id: String)

    var isRunning: Bool { get }
    
    func process(asset: UPlayerAssetProtocol) -> AnyPublisher<UPlayerAssetProtocol, Error>
    func cancel()
}

public protocol UPlayerAssetProcessorsQueueDelegate: AnyObject {
    func didStartProcessing(source: UPlayerAssetProcessorsQueueProtocol)
    func didFinishProcessing(source: UPlayerAssetProcessorsQueueProtocol, error: Error?)
    func didFinishProcessing(source: UPlayerAssetProcessorsQueueProtocol, asset: UPlayerAssetProtocol)
}

public protocol UPlayerAssetProcessorsQueueProtocol: AnyObject {
    var isRunning: Bool { get }
    var current: UPlayerAssetProcessorProtocol? { get }
    var delegate: UPlayerAssetProcessorsQueueDelegate? { get set }

    func start(asset: UPlayerAssetProtocol)
    func stop()
    
    func add(processor: UPlayerAssetProcessorProtocol)
    func remove(processor: UPlayerAssetProcessorProtocol)
}

public class UPlayerAssetProcessorsQueue: UPlayerAssetProcessorsQueueProtocol {
    
    // MARK: Fields
    
    private var processors = [UPlayerAssetProcessorProtocol]()
    private var cancellables = Set<AnyCancellable>()

    // MARK: Constructors/Destructor
    
    public init() {}

    // MARK: UPlayerAssetProcessorsQueueProtocol
    
    public weak var delegate: UPlayerAssetProcessorsQueueDelegate?
    
    public var isRunning: Bool {
        return current != nil
    }
    
    public var current: UPlayerAssetProcessorProtocol? {
        return processors.first { listed in
            return listed.isRunning
        }
    }

    public func start(asset: UPlayerAssetProtocol) {
        delegate?.didStartProcessing(source: self)
        
        log("\(logScope) started", loggingLevel: .debug)

        processors.reduce(
            Just(asset)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        ) { chain, processor in
            
            chain.flatMap { asset in
                log("\(logScope) proccessing: \(asset.url)", loggingLevel: .debug)
                return processor.process(asset: asset)
            }
            .eraseToAnyPublisher()
        }
        .sink(
            receiveCompletion: { [weak self] completion in
                guard let self else {
                    return
                }
                switch completion {
                case .finished:
                    log("\(logScope) succeed", loggingLevel: .debug)
                case .failure(let error):
                    log("\(logScope) failed: \(error)", loggingLevel: .error)
                    self.delegate?.didFinishProcessing(source: self, error: error)
                }
            },
            receiveValue: { [weak self] finalAsset in
                guard let self else {
                    return
                }
                log("\(logScope) end", loggingLevel: .debug)
                self.delegate?.didFinishProcessing(source: self, asset: finalAsset)
            }
        )
        .store(in: &cancellables)
    }
    
    public func stop() {
        processors.forEach { listed in
            listed.cancel()
        }
    }
    
    public func add(processor: UPlayerAssetProcessorProtocol) {
        let isContains = processors.contains { listed in
            return listed.id == processor.id
        }
        if isContains {
            return
        }
        
        processors.append(processor)
    }
    
    public func remove(processor: UPlayerAssetProcessorProtocol) {
        processors.removeAll { listed in
            return listed.id == processor.id
        }
    }
}
