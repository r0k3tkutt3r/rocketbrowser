import UIKit

/// Safari's motion between a page and the tab overview, measured off a screen recording
/// of Safari itself. Opening: the page is already a rounded card following the finger
/// (`BrowserViewController.liftPage`); on release that card flies into its slot in the
/// grid, cropping to the slot's 3:4 as it goes, while the grid's controls fade in.
/// Closing retraces the same path — the chosen card grows back into the page — because
/// what leaves one way must come back the same way.
final class TabOverviewTransition: NSObject, UIViewControllerTransitioningDelegate {

    /// The finger's vertical speed at release (pt/s, negative is up), for the spring.
    var releaseVelocity: CGFloat = 0

    func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                             source: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        OpenOverview(releaseVelocity: releaseVelocity)
    }

    func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
        CloseOverview()
    }

    /// The overview card's picture corner radius, which the flying page lands on.
    static let cardRadius: CGFloat = 18
}

private final class OpenOverview: NSObject, UIViewControllerAnimatedTransitioning {

    let releaseVelocity: CGFloat

    init(releaseVelocity: CGFloat) {
        self.releaseVelocity = releaseVelocity
    }

    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval { 0.5 }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        guard let overview = context.viewController(forKey: .to) as? TabsViewController,
              let browser = context.viewController(forKey: .from) as? BrowserViewController,
              let overviewView = context.view(forKey: .to) else {
            context.completeTransition(true)
            return
        }
        let container = context.containerView
        overviewView.frame = context.finalFrame(for: overview)
        overviewView.alpha = 0
        container.addSubview(overviewView)
        overviewView.layoutIfNeeded()

        let tab = browser.currentTab
        browser.enterLiftedState()
        guard let slot = overview.cardFrame(for: tab, in: container),
              let flight = FlightCard(page: browser.pageSnapshot(), frame: browser.pageFrame(in: container),
                                      cornerRadius: browser.liftedCornerRadius) else {
            UIView.animate(withDuration: 0.3) { overviewView.alpha = 1 } completion: { _ in
                browser.leaveLiftedState()
                context.completeTransition(!context.transitionWasCancelled)
            }
            return
        }
        overview.setCard(for: tab, hidden: true)
        browser.hidePage()
        container.addSubview(flight)

        // Hand the finger's speed to the spring, relative to the distance left to fly.
        let distance = flight.frame.midY - slot.midY
        let relative = distance > 1 ? max(0, min(12, -releaseVelocity / distance)) : 0
        // A touch of bounce: the card was thrown, so it may settle, as Safari's does.
        let flightAnimator = UIViewPropertyAnimator(duration: 0.5, timingParameters: UISpringTimingParameters(
            dampingRatio: 0.86, initialVelocity: CGVector(dx: relative, dy: relative)))
        flightAnimator.addAnimations { flight.land(in: slot, cornerRadius: TabOverviewTransition.cardRadius) }
        flightAnimator.addCompletion { _ in
            overview.setCard(for: tab, hidden: false)
            flight.removeFromSuperview()
            browser.leaveLiftedState()
            context.completeTransition(!context.transitionWasCancelled)
        }
        flightAnimator.startAnimation()
        UIView.animate(withDuration: 0.25, delay: 0.05, options: [.curveEaseOut]) { overviewView.alpha = 1 }
    }
}

private final class CloseOverview: NSObject, UIViewControllerAnimatedTransitioning {

    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval { 0.45 }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        guard let overview = context.viewController(forKey: .from) as? TabsViewController,
              let browser = context.viewController(forKey: .to) as? BrowserViewController,
              let overviewView = context.view(forKey: .from),
              let browserView = context.view(forKey: .to) else {
            context.completeTransition(true)
            return
        }
        let container = context.containerView
        browserView.frame = context.finalFrame(for: browser)
        browserView.layoutIfNeeded()
        let tab = browser.currentTab

        // A tab with no card here (just created with +) has no path to retrace: fade.
        guard let slot = overview.cardFrame(for: tab, in: container) else {
            container.insertSubview(browserView, belowSubview: overviewView)
            UIView.animate(withDuration: 0.3) { overviewView.alpha = 0 } completion: { _ in
                context.completeTransition(!context.transitionWasCancelled)
            }
            return
        }
        overview.setCard(for: tab, hidden: true)
        container.addSubview(browserView)

        // The whole browser, scaled so its page sits exactly on the card and masked to
        // the card's 3:4 crop, then grown back to the screen: the live page, not a picture.
        let page = browser.pageFrame(in: browserView)
        let scale = slot.width / page.width
        let center = CGPoint(x: browserView.bounds.midX, y: browserView.bounds.midY)
        let shift = CGPoint(x: slot.minX - (center.x + scale * (page.minX - center.x)),
                            y: slot.minY - (center.y + scale * (page.minY - center.y)))
        browserView.transform = CGAffineTransform(translationX: shift.x, y: shift.y).scaledBy(x: scale, y: scale)
        let mask = UIView(frame: CGRect(x: page.minX, y: page.minY, width: page.width, height: page.width * 4 / 3))
        mask.backgroundColor = .black
        mask.layer.cornerCurve = .continuous
        mask.layer.cornerRadius = TabOverviewTransition.cardRadius / scale
        browserView.mask = mask

        let animator = UIViewPropertyAnimator(duration: 0.45, timingParameters: UISpringTimingParameters(dampingRatio: 1))
        animator.addAnimations {
            browserView.transform = .identity
            mask.frame = browserView.bounds
            mask.layer.cornerRadius = 0
        }
        animator.addCompletion { _ in
            browserView.mask = nil
            context.completeTransition(!context.transitionWasCancelled)
        }
        animator.startAnimation()
        UIView.animate(withDuration: 0.25, delay: 0.1, options: [.curveEaseIn]) { overviewView.alpha = 0 }
    }
}

/// The page in flight: a clipped window onto a full-size picture of the page, anchored
/// at its top. Shrinking the window to the slot's 3:4 while scaling the picture to the
/// slot's width is what crops the bottom of the page away on the way in.
private final class FlightCard: UIView {

    private let page: UIView
    private let pageWidth: CGFloat

    init?(page: UIView?, frame: CGRect, cornerRadius: CGFloat) {
        guard let page, page.bounds.width > 0 else { return nil }
        self.page = page
        pageWidth = page.bounds.width
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerCurve = .continuous
        layer.cornerRadius = cornerRadius
        page.layer.anchorPoint = .zero
        page.layer.position = .zero
        page.transform = CGAffineTransform(scaleX: frame.width / pageWidth, y: frame.width / pageWidth)
        addSubview(page)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func land(in slot: CGRect, cornerRadius: CGFloat) {
        frame = slot
        layer.cornerRadius = cornerRadius
        page.transform = CGAffineTransform(scaleX: slot.width / pageWidth, y: slot.width / pageWidth)
    }
}

extension UIWindow {

    /// Normal and incognito are different places, so moving between them passes
    /// through black — half the time going dark, the change made unseen, half coming
    /// back — instead of the whole screen flipping from light to dark in one frame.
    func fadeThroughBlack(duration: TimeInterval = 1, midpoint: @escaping () -> Void) {
        let curtain = UIView(frame: bounds)
        curtain.backgroundColor = .black
        curtain.alpha = 0
        curtain.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(curtain)
        UIView.animate(withDuration: duration / 2, delay: 0, options: [.curveEaseIn]) {
            curtain.alpha = 1
        } completion: { _ in
            midpoint()
            UIView.animate(withDuration: duration / 2, delay: 0.05, options: [.curveEaseOut]) {
                curtain.alpha = 0
            } completion: { _ in
                curtain.removeFromSuperview()
            }
        }
    }
}
