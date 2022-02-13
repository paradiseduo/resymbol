//
//  File.swift
//  
//
//  Created by paradiseduo on 2022/1/12.
//

import Foundation

class DispatchLimitQueue {
    static let shared = DispatchLimitQueue()
    private var receiveQueues = [String: DispatchQueue]()
    private var limitSemaphores = [String: DispatchSemaphore]()
    
    func limit(queue: DispatchQueue, group: DispatchGroup? = nil, count: Int, handle: @escaping ()->()) {
        let label = "\(queue.label).limit"
        var limitSemaphore: DispatchSemaphore!
        var receiveQueue: DispatchQueue!
        if let q = receiveQueues[label], let s = limitSemaphores[label] {
            limitSemaphore = s
            receiveQueue = q
        } else {
            limitSemaphore = DispatchSemaphore(value: count)
            receiveQueue = DispatchQueue(label: label)
            limitSemaphores[label] = limitSemaphore
            receiveQueues[label] = receiveQueue
        }
        
        receiveQueue.async {
            let _ = limitSemaphore.wait(timeout: DispatchTime.distantFuture)
            queue.async(group: group) {
                defer {
                    limitSemaphore.signal()
                }
                handle()
            }
        }
    }
}
