//
//
//  Kin.swift
//
//  Created by Kin Foundation
//  Copyright © 2018 Kin Foundation. All rights reserved.
//
//  kinecosystem.org
//

import Foundation
import KinCoreSDK
import StellarErrors
import KinUtil
import MoveKin

let SDKVersion = "0.8.1"

public typealias KinUserStatsCallback = (UserStats?, Error?) -> ()
public typealias KinLoginCallback = (Error?) -> ()
public typealias KinCallback = (String?, Error?) -> ()
public typealias OrderConfirmationCallback = (ExternalOrderStatus?, Error?) -> ()

public enum ExternalOrderStatus {
    case pending
    case failed
    case completed(String)
}

public enum EcosystemExperience {
    case marketplace
    case history
    case backup((BREvent) -> ())
    case restore((BREvent) -> ())
}

public struct NativeOffer: Equatable {
    public let id: String
    public let title: String
    public let description: String
    public let amount: Int32
    public let image: String
    public let isModal: Bool
    public let offerType: OfferType
    public init(id: String,
                title: String,
                description: String,
                amount: Int32,
                image: String,
                offerType: OfferType = .spend,
                isModal: Bool = false) {
        self.id = id
        self.title = title
        self.description = description
        self.amount = amount
        self.image = image
        self.isModal = isModal
        self.offerType = offerType
    }
}

@available(iOS 9.0, *)
public class Kin {
    
    public static let shared = Kin()
    fileprivate(set) var core: Core?
    fileprivate weak var mpPresentingController: UIViewController?
    fileprivate var bi: BIClient!
    fileprivate var prestartBalanceObservers = [String : (Balance) -> ()]()
    fileprivate var prestartNativeOffers = [NativeOffer]()
    fileprivate let psBalanceObsLock = NSLock()
    fileprivate let psNativeOLock = NSLock()
    fileprivate let moveKinFlow = MoveKinFlow()
    fileprivate var nativeOffersInc:Int32 = -1
    fileprivate var brManager:BRManager?
    fileprivate init() {
        moveKinFlow.receiveDelegate = self
    }
    
    public var lastKnownBalance: Balance? {
        return core?.blockchain.lastBalance ?? nil
    }
    
    public var publicAddress: String? {
        return core?.blockchain.account?.publicAddress ?? nil
    }
    
    public var isActivated: Bool {
        return core?.onboarded ?? false
    }
    
    public var nativeOfferHandler: ((NativeOffer) -> ())?
    
    static func track<T: KBIEvent>(block: () throws -> (T)) {
        do {
            let event = try block()
            try Kin.shared.bi.send(event)
        } catch {
            logError("failed to send event, error: \(error)")
        }
    }
    
    public func start(environment: Environment) throws {
        guard core == nil else {
            return
        }
        
        bi = try BIClient(endpoint: URL(string: environment.BIURL)!)
        setupBIProxies()
        
        guard   let modelPath = Bundle.ecosystem.path(forResource: "KinEcosystem",
                                                      ofType: "momd") else {
            logError("start failed")
            throw KinEcosystemError.client(.internalInconsistency, nil)
        }
        let store: EcosystemData!
        let chain: Blockchain!
        do {
            store = try EcosystemData(modelName: "KinEcosystem",
                                      modelURL: URL(string: modelPath)!)
            chain = try Blockchain(environment: environment)
        } catch {
            logError("start failed")
            throw KinEcosystemError.client(.internalInconsistency, nil)
        }
        
        guard let marketplaceURL = URL(string: environment.marketplaceURL) else {
            throw KinEcosystemError.client(.badRequest, nil)
        }
        let network = EcosystemNet(config: EcosystemConfiguration(baseURL: marketplaceURL))
        core = try Core(environment: environment, network: network, data: store, blockchain: chain)
        
        psBalanceObsLock.lock()
        defer {
            psBalanceObsLock.unlock()
        }
        prestartBalanceObservers.forEach { identifier, block in
            _ = core!.blockchain.addBalanceObserver(with: block, identifier: identifier)
        }
        prestartBalanceObservers.removeAll()
        psNativeOLock.lock()
        defer {
            psNativeOLock.unlock()
        }
        try prestartNativeOffers.forEach({ offer in
            try add(nativeOffer: offer)
        })
        prestartNativeOffers.removeAll()
    }
    
    public func login(jwt: String, callback: KinLoginCallback? = nil) throws {
       
        Kin.track { try UserLoginRequested() }
       
        guard let core = core else {
            logError("Kin not started")
            let error = KinEcosystemError.client(.notStarted, nil)
            callback?(error)
            Kin.track { try UserLoginFailed(errorReason: error.localizedDescription) }
            throw error
        }
        
        let jwtObj = try JWTObject(with: jwt)
        
        DispatchQueue.once(token: "com.kin.init") {
           Kin.track { try KinSDKInitiated() }
        }
        
        let lastUser = UserDefaults.standard.string(forKey: KinPreferenceKey.lastSignedInUser.rawValue)
        let lastDevice = UserDefaults.standard.string(forKey: KinPreferenceKey.lastSignedInDevice.rawValue)
        let lastEnvironmentName = UserDefaults.standard.string(forKey: KinPreferenceKey.lastEnvironment.rawValue)
        
        var needsLogout = false
        if lastUser != jwtObj.userId ||
            lastEnvironmentName != core.environment.name ||
            lastDevice != jwtObj.deviceId {
            logInfo("user / environment / device change detected - logging out first...")
            UserDefaults.standard.set(false, forKey: KinPreferenceKey.firstSpendSubmitted.rawValue)
            UserDefaults.standard.removeObject(forKey: KinPreferenceKey.lastSignedInUser.rawValue)
            UserDefaults.standard.removeObject(forKey: KinPreferenceKey.lastSignedInDevice.rawValue)
            UserDefaults.standard.removeObject(forKey: KinPreferenceKey.lastEnvironment.rawValue)
            needsLogout = true
        }
        
        prepareLogin(needsLogout, jwt: jwtObj)
        .then {
            self.attempOnboard(core)
        }.then {
            UserDefaults.standard.set(jwtObj.userId, forKey: KinPreferenceKey.lastSignedInUser.rawValue)
            UserDefaults.standard.set(jwtObj.deviceId, forKey: KinPreferenceKey.lastSignedInDevice.rawValue)
            UserDefaults.standard.set(core.environment.name, forKey: KinPreferenceKey.lastEnvironment.rawValue)
            logInfo("blockchain onboarded successfully")
            Kin.track { try UserLoginSucceeded() }
            callback?(nil)
            self.updateData(with: OffersList.self, from: "offers").error { error in
                logError("data sync failed (\(error))")
                }.then {
                    self.updateData(with: OrdersList.self, from: "orders").error { error in
                        logError("data sync failed (\(error))")
                    }
            }
        }.error { error in
            let tError = KinEcosystemError.transform(error)
            Kin.track { try UserLoginFailed(errorReason: tError.localizedDescription) }
            callback?(tError)
        }
    }
    
    public func logout() {
        guard let core = core else {
            logError("Kin not started")
            return
        }
        core.offboard()
    }
    
    public func balance(_ completion: @escaping (Balance?, Error?) -> ()) {
        guard let core = core else {
            logError("Kin not started")
            completion(nil, KinEcosystemError.client(.notStarted, nil))
            return
        }
        core.onboard().then {
            core.blockchain.balance()
        }.then(on: DispatchQueue.main) { balance in
            completion(Balance(amount: balance), nil)
            }.error { error in
                let esError: KinEcosystemError
                switch error {
                    case KinError.internalInconsistency,
                         KinError.accountDeleted:
                        esError = KinEcosystemError.client(.internalInconsistency, error)
                    case KinError.balanceQueryFailed(let queryError):
                        switch queryError {
                        case StellarError.missingAccount:
                            esError = KinEcosystemError.blockchain(.notFound, error)
                        case StellarError.missingBalance:
                            esError = KinEcosystemError.blockchain(.activation, error)
                        case StellarError.unknownError:
                            esError = KinEcosystemError.unknown(.unknown, error)
                        default:
                            esError = KinEcosystemError.unknown(.unknown, error)
                        }
                    default:
                        esError = KinEcosystemError.unknown(.unknown, error)
                }
                completion(nil, esError)
        }.error { error in
            completion(nil, KinEcosystemError.transform(error))
        }
    }
    
    public func addBalanceObserver(with block:@escaping (Balance) -> ()) -> String {
        guard let core = core else {
            psBalanceObsLock.lock()
            defer {
                psBalanceObsLock.unlock()
            }
            let observerIdentifier = UUID().uuidString
            prestartBalanceObservers[observerIdentifier] = block
            return observerIdentifier
        }
        return core.blockchain.addBalanceObserver(with: block)
    }
    
    public func removeBalanceObserver(_ identifier: String) {
        guard let core = core else {
            psBalanceObsLock.lock()
            defer {
                psBalanceObsLock.unlock()
            }
            prestartBalanceObservers[identifier] = nil
            return
        }
        core.blockchain.removeBalanceObserver(with: identifier)
    }
        
    @available(*, unavailable, renamed: "launchEcosystem(from:at:)")
    public func launchMarketplace(from parentViewController: UIViewController) throws {}
    
    public func launchEcosystem(from parentViewController: UIViewController, at experience: EcosystemExperience = .marketplace) throws {
        Kin.track { try EntrypointButtonTapped() }
        guard let core = core else {
            logError("Kin not started")
            throw KinEcosystemError.client(.notStarted, nil)
        }
        
        if case let .backup(handler) = experience {
            guard isActivated else { throw KinEcosystemError.service(.notLoggedIn, nil) }
            brManager = BRManager(with: self)
            brManager!.start(.backup, presentedOn: parentViewController) { success in
                if success {
                    handler(.backup(.done))
                } else {
                    handler(.backup(.cancel))
                }
            }
            return
        } else if case let .restore(handler) = experience {
            guard isActivated else { throw KinEcosystemError.service(.notLoggedIn, nil) }
            brManager = BRManager(with: self)
            brManager!.start(.restore, presentedOn: parentViewController) { success in
                if success {
                    handler(.restore(.done))
                } else {
                    handler(.restore(.cancel))
                }
            }
            return
        }
        
        mpPresentingController = parentViewController
        if isActivated {
            let mpViewController = MarketplaceViewController(nibName: "MarketplaceViewController", bundle: Bundle.ecosystem)
            mpViewController.core = core
            let navigationController = KinNavigationViewController(nibName: "KinNavigationViewController",
                                                                   bundle: Bundle.ecosystem,
                                                                   rootViewController: mpViewController,
                                                                   core: core)
            if case EcosystemExperience.history = experience {
                navigationController.transitionToOrders(animated: false)
            }
            parentViewController.present(navigationController, animated: true)
        } else {
            let welcomeVC = WelcomeViewController(nibName: "WelcomeViewController", bundle: Bundle.ecosystem)
            welcomeVC.core = core
            parentViewController.present(welcomeVC, animated: true)
        }
    }
    
    public func hasAccount(peer: String, handler: @escaping (Bool?, Error?) -> ()) {
        guard let core = core else {
            logError("Kin not started")
            DispatchQueue.main.async {
                handler(nil, KinEcosystemError.client(.notStarted, nil))
            }
            return
        }
        _ = core.onboard()
            .then {
                core.network.dataAtPath("users/exists",
                                    method: .get,
                                    contentType: .json,
                                    parameters: ["user_id" : peer])
            }.then { data in
                if  let response = String(data: data, encoding: .utf8),
                    let ans = Bool(response) {
                    DispatchQueue.main.async {
                        handler(ans, nil)
                    }
                } else {
                    DispatchQueue.main.async {
                        handler(nil, KinEcosystemError.service(.response, nil))
                    }
                }
            }.error { error in
                DispatchQueue.main.async {
                    handler(nil, KinEcosystemError.transform(error))
                }
        }
    }
    
    public func payToUser(offerJWT: String, completion: @escaping KinCallback) -> Bool {
        return purchase(offerJWT: offerJWT, completion: completion)
    }
    
    public func purchase(offerJWT: String, completion: @escaping KinCallback) -> Bool {
        guard let core = core else {
            logError("Kin not started")
            completion(nil, KinEcosystemError.client(.notStarted, nil))
            return false
        }
        defer {
            core.onboard()
            .then {
                Flows.nativeSpend(jwt: offerJWT, core: core)
            }.then { jwt in
                completion(jwt, nil)
            }.error { error in
                completion(nil, KinEcosystemError.transform(error))
            }
        }
        return true
    }
    
    public func requestPayment(offerJWT: String, completion: @escaping KinCallback) -> Bool {
        guard let core = core else {
            logError("Kin not started")
            completion(nil, KinEcosystemError.client(.notStarted, nil))
            return false
        }
        defer {
            core.onboard()
            .then {
                Flows.nativeEarn(jwt: offerJWT, core: core)
            }.then { jwt in
                completion(jwt, nil)
            }.error { error in
                completion(nil, KinEcosystemError.transform(error))
            }
        }
        return true
    }
    
    public func orderConfirmation(for offerID: String, completion: @escaping OrderConfirmationCallback) {
        guard let core = core else {
            logError("Kin not started")
            completion(nil, KinEcosystemError.client(.notStarted, nil))
            return
        }
        core.onboard()
        .then { [weak self] (_) -> KinUtil.Promise<Void> in
            guard let this = self else {
                return KinUtil.Promise<Void>().signal(KinError.internalInconsistency)
            }
            return this.updateData(with: OrdersList.self, from: "orders")
        }.then {
                core.data.queryObjects(of: Order.self, with: NSPredicate(with: ["offer_id":offerID]), queryBlock: { orders in
                    guard let order = orders.first else {
                        let responseError = ResponseError(code: 4043, error: "NotFound", message: "Order not found")
                        completion(nil, KinEcosystemError.service(.response, responseError))
                        return
                    }
                    switch order.orderStatus {
                    case .pending,
                         .delayed:
                       completion(.pending, nil)
                    case .completed:
                        guard let jwt = (order.result as? JWTConfirmation)?.jwt else {
                            completion(nil, KinEcosystemError.client(.internalInconsistency, nil))
                            return
                        }
                        completion(.completed(jwt), nil)
                    case .failed:
                        completion(.failed, nil)
                    }
                })
        }.error { error in
                completion(nil, KinEcosystemError.transform(error))
        }
    }
    
    public func setLogLevel(_ level: LogLevel) {
        Logger.setLogLevel(level)
    }
    
    public func add(nativeOffer: NativeOffer) throws {
        guard let core = core else {
            psNativeOLock.lock()
            defer {
                psNativeOLock.unlock()
            }
            prestartNativeOffers.append(nativeOffer)
            return
        }
        var offerExists = false
        core.data.queryObjects(of: Offer.self, with: NSPredicate(with: ["id" : nativeOffer.id])) { offers in
            offerExists = offers.count > 0
            }.then {
                guard offerExists == false else { return }
                core.data.stack.perform({ (context, _) in
                    let offer = try? Offer(with: nativeOffer, in: context)
                    offer?.position = self.nativeOffersInc
                    self.nativeOffersInc -= 1
                })
        }
    }
    
    public func remove(nativeOfferId: String) throws {
        guard let core = core else {
            psNativeOLock.lock()
            defer {
                psNativeOLock.unlock()
            }
            prestartNativeOffers = prestartNativeOffers.filter({ offer -> Bool in
                offer.id != nativeOfferId
            })
            return
        }
        _ = core.data.changeObjects(of: Offer.self, changeBlock: { context, offers in
            if let offer = offers.first {
                context.delete(offer)
            }
        }, with: NSPredicate(with: ["id" : nativeOfferId]))
    }
    
    public func userStats(handler: @escaping KinUserStatsCallback) {
        guard let core = core else {
            logError("Kin not started")
            handler(nil, KinEcosystemError.client(.notStarted, nil))
            return
        }
        core.onboard()
        .then {
            core.network.objectAtPath("users/me", type: UserProfile.self)
        }.then(on: DispatchQueue.main) { profile in
            handler(profile.stats, nil)
        }.error { error in
            DispatchQueue.main.async {
               handler(nil, KinEcosystemError.transform(error))
            }
        }
    }
    
    func prepareLogin(_ shouldLogout: Bool, jwt: JWTObject) -> KinUtil.Promise<Void> {
        guard let core = core else {
            return KinUtil.Promise<Void>().signal(KinEcosystemError.client(.notStarted, nil))
        }
        let p = KinUtil.Promise<Void>()
        guard shouldLogout else {
            core.jwt = jwt
            return p.signal(())
        }
        core.offboard().finally {
            core.jwt = jwt
            p.signal(())
        }
        return p
    }
    
    func updateData<T: EntityPresentor>(with dataPresentorType: T.Type, from path: String) -> KinUtil.Promise<Void> {
        guard let core = core else {
            logError("Kin not started")
            return KinUtil.Promise<Void>().signal(KinEcosystemError.client(.notStarted, nil))
        }
        return core.network.dataAtPath(path).then { data in
            return self.core!.data.sync(dataPresentorType, with: data)
        }
    }
    
    func closeMarketPlace(completion: (() -> ())? = nil) {
        mpPresentingController?.dismiss(animated: true, completion: completion)
    }
    
    @discardableResult
    func attempOnboard(_ core: Core) -> Promise<Void> {
        return attempt(2) { attempNum -> KinUtil.Promise<Void> in
                let p = KinUtil.Promise<Void>()
                logInfo("attempting onboard: \(attempNum)")
                //logVerbose("accounts at onboard begin:\n\n\(core.blockchain.client.accounts.debugInfo)")
                core.onboard()
                        .then {
                            //logVerbose("accounts at onboard end:\n\n\(core.blockchain.client.accounts.debugInfo)")
                            p.signal(())
                        }
                        .error { error in
                            if case KinEcosystemError.service(.timeout, _) = error {
                                core.network.client.authToken = nil
                                Kin.track { try GeneralEcosystemSDKError(errorReason: "Blockchain onboard timedout at attempt \(attempNum), resetting auth token") }
                            }
                            p.signal(error)
                    }
                .error { error in
                    logError("onboard attempt failed: \(error)")
                    p.signal(error)
                }
                return p
            }.error { error in
                let errorDesc = "blockchain onboarding failed - \(error.localizedDescription)"
                logError(errorDesc)
                Kin.track { try GeneralEcosystemSDKError(errorReason: errorDesc) }
        }
    }
    
    fileprivate func setupBIProxies() {
        EventsStore.shared.userProxy = UserProxy(balance: { [weak self] () -> (Double) in
            guard let balance = self?.core?.blockchain.lastBalance else {
                return 0
            }
            return NSDecimalNumber(decimal: balance.amount).doubleValue
            }, digitalServiceID: { [weak self] () -> (String) in
                return self?.core?.jwt?.appId ?? ""
            }, digitalServiceUserID: { [weak self] () -> (String) in
                return self?.core?.jwt?.userId ?? ""
            }, earnCount: { () -> (Int) in
                0
        }, entryPointParam: { () -> (String) in
            ""
        }, spendCount: { () -> (Int) in
            0
        }, totalKinEarned: { () -> (Double) in
            0
        }, totalKinSpent: { () -> (Double) in
            0
        }, transactionCount: { () -> (Int) in
            0
        })
        
        EventsStore.shared.clientProxy = ClientProxy(carrier: { [weak self] () -> (String) in
            return self?.bi.networkInfo.subscriberCellularProvider?.carrierName ?? ""
            }, deviceManufacturer: { () -> (String) in
                "Apple"
        }, deviceModel: { () -> (String) in
            UIDevice.current.model
        }, language: { () -> (String) in
            Locale.autoupdatingCurrent.languageCode ?? ""
        }, os: { () -> (String) in
            UIDevice.current.systemVersion
        })
        
        EventsStore.shared.commonProxy = CommonProxy(deviceID: { [weak self] () -> (String) in
            return self?.core?.jwt?.deviceId ?? ""
        }, eventID: { () -> (String) in
            UUID().uuidString
        }, timestamp: { () -> (String) in
            "\(Date().timeIntervalSince1970)"
        }, userID: { [weak self] () -> (String) in
            self?.core?.network.client.authToken?.ecosystem_user_id ?? ""
            }, version: { () -> (String) in
                SDKVersion
        })
    }
}

//MARK: - MoveKin

@available(iOS 9.0, *)
public extension Kin {
    public func canHandleURL(_ url: URL) -> Bool {
        guard moveKinFlow.canHandleURL(url) else {
            return false
        }

        return true
    }

    public func handleURL(_ url: URL, options: [UIApplication.OpenURLOptionsKey: Any]) {
        if let sourceApp = options[.sourceApplication] as? String,
            moveKinFlow.canHandleURL(url) {
            moveKinFlow.handleURL(url, from: sourceApp)
        }
    }
}

@available(iOS 9.0, *)
extension Kin: ReceiveKinFlowDelegate {
    public func acceptReceiveKinViewController() -> UIViewController & AcceptReceiveKinPage {
        return AcceptReceiveKinViewController()
    }

    public func provideUserAddress(addressHandler: @escaping (String?) -> Void) {
        addressHandler(publicAddress)
    }
}
