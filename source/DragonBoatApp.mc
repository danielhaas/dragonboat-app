using Toybox.Application;
using Toybox.WatchUi;

class DragonBoatApp extends Application.AppBase {
    var mainView;  // for onStop cleanup and the self-test memory stress test

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
        if (mainView != null) {
            mainView.shutdown();
        }
    }

    // Return the initial view of your application here
    function getInitialView() {
        var view = new DragonBoatView();
        mainView = view;
        var delegate = new DragonBoatDelegate(view);
        return [view, delegate];
    }
}
