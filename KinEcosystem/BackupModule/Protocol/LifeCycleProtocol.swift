//
//  LifeCycleProtocol.swift
//  KinEcosystem
//
//  Created by Corey Werner on 25/10/2018.
//  Copyright © 2018 Kik Interactive. All rights reserved.
//

import Foundation

protocol LifeCycleProtocol: NSObjectProtocol {
    func viewController(_ viewController: UIViewController, willAppear animated: Bool)
}