import Cocoa

var running = true

Resymbol.main()

while (running && RunLoop.current.run(mode: .default, before: Date.distantFuture)) {
    exit(0)
}
