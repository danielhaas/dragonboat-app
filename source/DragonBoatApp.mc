using Toybox.Application;
using Toybox.WatchUi;

class DragonBoatApp extends Application.AppBase {
    var view;

    function initialize() {
        AppBase.initialize();
    }

    // onStart() is called on application start up
    function onStart(state) {
        startSelfTest();
    }

    // Self-test build only (selftest.jungle): run the baked-in recording
    // through AnalyzerJob and log the stroke count.
    (:selftest)
    function startSelfTest() {
        new AnalyzerSelfTest().start();
    }

    (:noselftest)
    function startSelfTest() {
    }

    // onStop() is called when your application is exiting
    function onStop(state) {
        // Release GPS, HR and accelerometer explicitly. Some firmware keeps
        // them powered after exit if the app doesn't, draining the battery.
        if (view != null) {
            view.shutdown();
        }
    }

    // Return the initial view of your application here
    function getInitialView() {
        view = new DragonBoatView();
        var delegate = new DragonBoatDelegate(view);
        return [view, delegate];
    }
}
