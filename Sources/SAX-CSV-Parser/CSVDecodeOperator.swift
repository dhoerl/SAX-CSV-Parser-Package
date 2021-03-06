//
//  CSVDecodeOperator.swift
//  CSVParserInSwift
//
//  Created by David Hoerl on 2/18/20.
//  Copyright © 2020 David Hoerl. All rights reserved.
//

import Foundation
import Combine

private func LOG(_ items: Any..., separator: String = " ", terminator: String = "\n") {
#if DEBUG
    print("OPER: " + items.map{String(describing: $0)}.joined(separator: separator), terminator: terminator)
#endif
}

public struct AssetData<T> {
	let object: T
	let currentByteCount: Int64	// -1 means don't know
	let totalByteCount: Int64	// -1 means don't know
}

private let byteRequest = 4096

extension Publisher where Self.Output == AssetData<Data>, Self.Failure == Error {

	func csv2obj<T: CSVDecode>(
		queue: DispatchQueue,
		configuration: CSVConfiguration = CSVConfiguration(),
		defaults: T,
		recordScrubber: CSVRecordScrubber? = nil,
		byteRequest: Int = byteRequest
	) -> AnyPublisher<[AssetData<T>], Error> {
		let downstream = CSVDecodePublisher(queue: queue, upstream: self.eraseToAnyPublisher(), configuration: configuration, defaults: defaults, recordScrubber: recordScrubber, byteRequest: byteRequest)
		return downstream.eraseToAnyPublisher()
	}

}
extension Publisher where Self.Output == Data, Self.Failure == Error {

	func csv2obj<T: CSVDecode>(
		queue: DispatchQueue,
		configuration: CSVConfiguration = CSVConfiguration(),
		defaults: T,
		recordScrubber: CSVRecordScrubber? = nil,
		byteRequest: Int = byteRequest
	) -> AnyPublisher<[AssetData<T>], Error> {
		let downstream = CSVDecodePublisher(queue: queue, upstream: self.eraseToAnyPublisher(), configuration: configuration, defaults: defaults, recordScrubber: recordScrubber, byteRequest: byteRequest)
		return downstream.eraseToAnyPublisher()
	}

}
private struct CSVDecodePublisher<T: CSVDecode, P: Publisher>: Publisher {

	public typealias Output = [AssetData<T>]
	public typealias Failure = Error

	let queue: DispatchQueue
	let upstream: P // AnyPublisher<Data, Error>
	let configuration: CSVConfiguration
	let defaults: T
	let recordScrubber: CSVRecordScrubber?
	let byteRequest: Int

    func receive<S>(subscriber: S) where S: Subscriber, Failure == S.Failure, Output == S.Input {
		//guard let upstreamSubscriber = upstreamSubscriber else { fatalError() }

        let subscription = AssetFetcherSubscription(
			queue: queue,
			upstream: upstream,
			downstreamSubscriber: subscriber,
			configuration: configuration,
			defaults: defaults,
			recordScrubber: recordScrubber,
			byteRequest: byteRequest
        )
		upstream.subscribe(subscription)
    }

}

private extension CSVDecodePublisher {

    final class AssetFetcherSubscription<DownStream, P: Publisher>: NSObject, StreamDelegate, Subscription, Subscriber where DownStream: Subscriber, DownStream.Input == [AssetData<T>], DownStream.Failure == Error {

		typealias Input = P.Output 		// for Subscriber
		typealias Failure = P.Failure	// for Subscriber

        private var runningDemand: Subscribers.Demand = Subscribers.Demand.max(0)
        private var objects: Output = []	// same as DownStream.Input

        let queue: DispatchQueue
        var upstreamSubscription: Subscription? // AnySubscriber<AssetData<Data>, Error>
        let downstreamSubscriber: DownStream

		let configuration: CSVConfiguration
		let defaults: T
		let recordScrubber: CSVRecordScrubber?
		let byteRequest: Int

		lazy var csvParser: CSVParser = { CSVParser(streamDelegate: self, configuration: configuration, defaults: defaults, recordScrubber: recordScrubber) }()

        init(
			queue: DispatchQueue,
			upstream: P, // AnyPublisher<AssetData<Data>, Error>,
			downstreamSubscriber: DownStream,
			configuration: CSVConfiguration,
			defaults: T,
			recordScrubber: CSVRecordScrubber?,
			byteRequest: Int
        ) {
			self.queue = queue
			self.downstreamSubscriber = downstreamSubscriber
			self.configuration = configuration
			self.defaults = defaults
			self.recordScrubber = recordScrubber
			self.byteRequest = byteRequest

			super.init()
        }
        deinit {
            LOG("DEINIT")
#if UNIT_TESTING
            NotificationCenter.default.post(name: FetcherDeinit, object: nil, userInfo: [AssetURL: url])
#endif
        }

		// MARK: - Subscription

        func receive(subscription: Subscription) {	// AnySubscriber<Input, Failure>
			dispatchPrecondition(condition: .onQueue(queue))

			upstreamSubscription = subscription
			downstreamSubscriber.receive(subscription: self)

			csvParser.open()
			requestData()	// prime the pump
        }

		func receive(_ input: Input) -> Subscribers.Demand {
			dispatchPrecondition(condition: .onQueue(queue))

			let data: Data
			let current: Int64
			let total: Int64

			switch input {
			case let d as Data:
				LOG("HAHAHA")
				data = d
				current = -1
				total = -1
			case let asset as AssetData<Data>:
				LOG("GOOP")
				data = asset.object
				current = asset.currentByteCount
				total = asset.totalByteCount
			default:
				fatalError()
			}

			data.withUnsafeBytes { (bufPtr: UnsafeRawBufferPointer) in
				if let addr = bufPtr.baseAddress, bufPtr.count > 0 {
//print("IP WRITE BYTES[\(self.kvp.key)]:", bufPtr.count, "...")
					let ptr: UnsafePointer<UInt8> = addr.assumingMemoryBound(to: UInt8.self)
					let _ = self.csvParser.write(ptr, maxLength: bufPtr.count)
//print("...WRITE BYTES:", bufPtr.count)
				}
			}

			// save objects, if demand is there then send them, otherwise hold them. We get to typecast each too
			csvParser.currentObjects().forEach { (object) in
				guard let t = object as? T else { return }
				self.objects.append(AssetData<T>(object: t, currentByteCount: current, totalByteCount: total))
			}
			sendData()
			return Subscribers.Demand.unlimited
		}

		func receive(completion: Subscribers.Completion<Failure>) {
		}

		// MARK: Subscriber

        func request(_ demand: Subscribers.Demand) {
            LOG("REQUEST")
            // demand is additive: https://www.donnywals.com/understanding-combines-publishers-and-subscribers/
            runningDemand += demand

            sendData()
        }
        func cancel() {
            LOG("CANCELLED")
			guard let upstreamSubscription = upstreamSubscription else { return }

            upstreamSubscription.cancel()
            self.upstreamSubscription = nil
            csvParser.close()
//            AssetFetcher.assetQueue.async {
//                self.fetcher.close()
//            }
        }

		// MARK: - Utility -

		private func sendData() {
			let haveCount = objects.count
			let sendCount = howMuchToSend()

			let sendArray: [AssetData<T>]
			if sendCount == haveCount {
				sendArray = objects
				objects.removeAll()
			} else {
				sendArray = Array<AssetData<T>>(objects.prefix(sendCount))
				objects.removeFirst(sendCount)
			}

			queue.async {
				let residualDemand = self.downstreamSubscriber.receive(sendArray)
				LOG("Residual Demand", residualDemand)
			}

			if objects.isEmpty {
				requestData()
			}
		}

        private func howMuchToSend() -> Int {
			let haveLen = objects.count
            let askLen: Int
            if let demandMax = runningDemand.max {
                askLen = haveLen < demandMax ? haveLen : demandMax
            } else {
                askLen = haveLen	// infinite demand
            }
            return askLen
        }

		private func requestData() {
			guard let upstreamSubscription = upstreamSubscription else { return }
			let howMuch = Subscribers.Demand.max(byteRequest)
			queue.async { upstreamSubscription.request(howMuch) }
		}

		@objc
		func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
			//dispatchPrecondition(condition: .onQueue(assetQueue))
			guard let stream = aStream as? OutputStream else { fatalError() }

			var closeStream = false
	//print("EVENTS:", events, "CODE:", eventCode.rawValue)
			switch eventCode {
			case .openCompleted:
				break
			case .endEncountered:
				closeStream = true
				break
			case .hasBytesAvailable, .hasSpaceAvailable:
				break
			case .errorOccurred:
				aStream.close()
				if let error = aStream.streamError {
					LOG("WTF!!! Error:", error)
				} else {
					LOG("ERROR BUT NO STREAM ERROR!!!")
				}
				closeStream = true
			default:
				LOG("UNEXPECTED \(eventCode)", String(describing: eventCode))
				break
			}
			if closeStream {
				stream.close()
			}
		}

#if false
        func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
LOG("Stream...")
            guard let downstream = downstream else { return }
            guard let stream = aStream as? InputStream else { fatalError() }
            dispatchPrecondition(condition: .onQueue(AssetFetcher.assetQueue))

            switch eventCode {
            case .openCompleted:
                LOG("stream.openCompleted)")
            case .endEncountered:
                LOG("stream.endEncountered")
                fetcher.close()
                downstream.receive(completion: .finished)
            case .hasBytesAvailable:
                LOG("stream.hasBytesAvailable")
                guard stream.hasBytesAvailable else { return }

                var askLen: Int
                do {
                    //var byte: UInt8 = 0
                    var ptr: UnsafeMutablePointer<UInt8>? = nil
                    var len: Int = 0

                    if stream.getBuffer(&ptr, length: &len) {
                        askLen = len
                    } else {
                        askLen = standardCount
                    }
                }
                askLen = howMuchToRead(request: askLen)
                LOG("stream.askLen=\(askLen)")
                if askLen > 0 {
                    // We have outstanding requests
                    let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: askLen)  // mutable Data won't let us get a pointer anymore...
LOG("read...")
                    let readLen = stream.read(bytes, maxLength: askLen)
LOG("...read")
                    let data = Data(bytesNoCopy: bytes, count: readLen, deallocator: .custom({ (_, _) in bytes.deallocate() })) // (UnsafeMutableRawPointer, Int)

LOG("downstream.receive(data)...")
                    let assetData = AssetData(data: data, size: fetcher.size)
                    let _ = downstream.receive(assetData)
LOG("...downstream.receive(data)")
                    LOG("stream.read=\(readLen) bytes")
                } else {
                    // No outstanding requests, so buffer the data
                    let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: standardCount)  // mutable Data won't let us get a pointer anymore...
                    let readLen = stream.read(bytes, maxLength: standardCount)
                    savedData.append(bytes, count: readLen)
                    LOG("stream.cache\(readLen) bytes")
                }
            case .errorOccurred:
                fetcher.close()
                let err = stream.streamError ?? NSError(domain: "com.AssetFetcher", code: 0, userInfo: [NSLocalizedDescriptionKey: "Unknown Error"])
                LOG("stream.error=\(err)")
                downstream.receive(completion: .failure(err))
            default:
                LOG("UNEXPECTED \(eventCode)", String(describing: eventCode))
                fatalError()
            }
		}
#endif
	}

}

/*
/*

	init(
		upstream: AnyPublisher<Data, Error>,
		configuration: CSVConfiguration,
		defaults: T,
		recordScrubber: CSVRecordScrubber
	) {
		upstream = self
		configuration = configuration

	}

            .sink(receiveCompletion: { (completion) in
                    let block: (TiledImageBuilder) -> Result<TilingView, Error>

                    switch completion {
                    case .finished:
                        assert(self.imageBuilder.finished)
                        assert(!self.imageBuilder.failed);
                        block = { (tb: TiledImageBuilder) in
                            let tv = TilingView(imageBuilder: tb)
                            print("SUCCESS! IMAGE SIZE:", tv.imageSize())
                            return .success(tv)
                        }
                    case .failure(let error):
                        block = { _ in
                            print("ERROR:", error)
                            return .failure(error)
                        }
                    }
                    self.imageBuilder.close()

                    var retVal = self.imageResult
                    DispatchQueue.main.async {
                        retVal.result = block(self.imageBuilder)
                        self.imageResult = retVal
                    }
                },
                receiveValue: { (assetData) in
                    var retVal = self.imageResult
//imageResult.ucbUsage = TiledImageBuilder.ubcUsage

                    assetData.data.withUnsafeBytes { (bufPtr: UnsafeRawBufferPointer) in
                        if let addr = bufPtr.baseAddress, bufPtr.count > 0 {
//print("IP WRITE BYTES[\(self.kvp.key)]:", bufPtr.count, "...")
                            let ptr: UnsafePointer<UInt8> = addr.assumingMemoryBound(to: UInt8.self)
                            self.imageBuilder.write(ptr, maxLength: bufPtr.count)
//print("...WRITE BYTES:", bufPtr.count)
                            retVal.assetSize = assetData.size
                            retVal.assetSizeProgress += Int64(bufPtr.count)
                        }
                    }
                    DispatchQueue.main.async {
                        self.imageResult = retVal
                    }
                }

*/



public struct CSVDecodePublisher<T: CSVDecode>: Publisher {

    //static var assetQueue = DispatchQueue.main
    //static private var _assetQueue: DispatchQueue { DispatchQueue(label: "com.CSVDecodePublisher", qos: .userInitiated) }

    public typealias Output = AssetData<T>
    public typealias Failure = Error

	let cancellable: AnyCancellable

//	init(publisher: Publisher<Data, Error>) {
//		self.cancellable = publisher.receive<S>(subscriber: S) where S : Subscriber, Self.Failure == S.Failure, Self.Output == S.Input
//	}

/*
class Client : Subscriber {
  typealias Input = String
  typealias Failure = Never

  let service:Service
  var subscription:Subscription?

  init(service:Service) {
    self.service = service

   // Is this a retain cycle?
   // Is this thread-safe?
    self.service.tweets.subscribe(self)
  }

  func receive(subscription: Subscription) {
    print("Received subscription: \(subscription)")

    self.subscription = subscription
    self.subscription?.request(.unlimited)
  }

  func receive(_ input: String) -> Subscribers.Demand {
    print("Received tweet: \(input)")
    return .unlimited
  }

  func receive(completion: Subscribers.Completion<Never>) {
    print("Received completion")
  }
}
	*/

//    let url: URL
//
//    init(url: URL) {
//        self.url = url
//    }
//    deinit {
//#if UNIT_TESTING
//        NotificationCenter.default.post(name: FetcherDeinit, object: nil, userInfo: [AssetURL: url])
//#endif
//    }

//    // Must be called prior to instantiating any objects
//    static func startMonitoring(onQueue: DispatchQueue?) {
//        guard assetQueue == DispatchQueue.main else { return }   // Mostly a Unit Testing issue
//        assetQueue = onQueue ?? _assetQueue
//        WebFetcherStream.startMonitoring(onQueue: assetQueue)
//    }

*/


//	init(publisher: Publisher<Data, Error>) {
//		self.cancellable = publisher.receive<S>(subscriber: S) where S : Subscriber, Self.Failure == S.Failure, Self.Output == S.Input
//	}
//		self.receive
//    var cache: [Self.Output:P.Output] = [:]
//    return self.flatMap({ input -> AnyPublisher<P.Output,P.Failure> in
//      if let result = cache[input] {
//        return Just(result).setFailureType(to: P.Failure.self).eraseToAnyPublisher()
//      }
//      else {
//        return operation(input).map({ result in
//          cache[input] = result
//          return result
//        }).eraseToAnyPublisher()
//      }
//    }).eraseToAnyPublisher()
//	}
//
//}


//			self.upstream = upstream.sink(
//
//				receiveCompletion: { (completion) in
//	//			let block: (TiledImageBuilder) -> Result<TilingView, Error>
//	//
//	//			switch completion {
//	//			case .finished:
//	//				assert(self.imageBuilder.finished)
//	//				assert(!self.imageBuilder.failed);
//	//				block = { (tb: TiledImageBuilder) in
//	//					let tv = TilingView(imageBuilder: tb)
//	//					print("SUCCESS! IMAGE SIZE:", tv.imageSize())
//	//					return .success(tv)
//	//				}
//	//			case .failure(let error):
//	//				block = { _ in
//	//					print("ERROR:", error)
//	//					return .failure(error)
//	//				}
//	//			}
//	//			self.imageBuilder.close()
//	//
//	//			var retVal = self.imageResult
//	//			DispatchQueue.main.async {
//	//				retVal.result = block(self.imageBuilder)
//	//				self.imageResult = retVal
//	//			}
//				},
//				receiveValue: { [weak weakSelf = self] (assetData) in
//					guard let strongSelf = weakSelf else { return }
//					let parser = strongSelf.parser
//		//	//imageResult.ucbUsage = TiledImageBuilder.ubcUsage
//		//
//	//				strongSelf.totalBytes = assetData.totalByteCount
//	//				strongSelf.currentBytes = assetData.currentByteCount
//
//					assetData.object.withUnsafeBytes { (bufPtr: UnsafeRawBufferPointer) in
//						if let addr = bufPtr.baseAddress, bufPtr.count > 0 {
//			//print("IP WRITE BYTES[\(self.kvp.key)]:", bufPtr.count, "...")
//							let ptr: UnsafePointer<UInt8> = addr.assumingMemoryBound(to: UInt8.self)
//							let _ = strongSelf.parser.write(ptr, maxLength: bufPtr.count)
//							parser.currentObjects().forEach { (object) in
//								guard let t = object as? T else { return }
//								strongSelf.objects.append(AssetData<T>(object: t, currentByteCount: assetData.currentByteCount, totalByteCount: assetData.totalByteCount))
//							}
//						}
//					}
//		//			DispatchQueue.main.async {
//		//				self.imageResult = retVal
//		//			}
//				}
//			)
////			defer {
////			parser = CSVParser(streamDelegate: self, configuration: configuration, defaults: defaults, recordScrubber: recordScrubber)
//			parser.open()
////			}
//
//
//            //self.url = url
////            self.downstream = downstream
////
////            AssetFetcher.assetQueue.async {
////                self.fetcher.open()
////            }
////            LOG("INIT")

//            let askLen = howMuchToRead(request: standardCount)
//            LOG("request, demand:", demand.max ?? "<infinite>", "runningDemand:", runningDemand.max ?? "<infinite>", "ASKLEN:", askLen)
//
//            if askLen > 0 && savedData.count > 0 {
//                let readLen = askLen > savedData.count ? savedData.count : askLen // min won't work
//                let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: readLen)  // mutable Data won't let us get a pointer anymore...
//                let range = 0..<readLen
//                savedData.copyBytes(to: bytes, from: range)
//                let data = Data(bytesNoCopy: bytes, count: readLen, deallocator: .custom({ (_, _) in bytes.deallocate() })) // (UnsafeMutableRawPointer, Int)
//                //let assetData = AssetData(data: data, size: fetcher.size)
//
//                savedData.removeSubrange(range)
//
////                let assetData: AssetData<Data> = AssetData<Data>(object: data, currentByteCount: -1, totalByteCount: -1)
////                let _ = downstream.receive(assetData)
//            }
