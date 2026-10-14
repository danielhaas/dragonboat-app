using Toybox.Application;
using Toybox.WatchUi;

class DragonBoatApp extends Application.AppBase {

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
    }

    // Return the initial view of your application here
    function getInitialView() {
        var view = new DragonBoatView();
        var delegate = new DragonBoatDelegate(view);
        return [view, delegate];
    }
}
