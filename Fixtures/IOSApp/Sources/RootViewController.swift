import UIKit

final class RootViewController: UIViewController {
    let label = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        label.text = Greeter(name: "ios").greeting()
        view.addSubview(label)
    }
}
