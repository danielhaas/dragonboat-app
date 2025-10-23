using Toybox.WatchUi;
using Toybox.System;

class DragonBoatDelegate extends WatchUi.BehaviorDelegate {
    var view;

    function initialize(dragonBoatView) {
        BehaviorDelegate.initialize();
        view = dragonBoatView;
    }

    // Handle menu button (back button long press)
    function onMenu() {
        // Show confirmation menu to save or discard
        WatchUi.pushView(new WatchUi.Confirmation("Save Activity?"), new SaveConfirmationDelegate(view), WatchUi.SLIDE_IMMEDIATE);
        return true;
    }

    // Handle back button
    function onBack() {
        // Show confirmation menu to save or discard
        WatchUi.pushView(new WatchUi.Confirmation("Save Activity?"), new SaveConfirmationDelegate(view), WatchUi.SLIDE_IMMEDIATE);
        return true;
    }

    // Handle up button - switch view
    function onNextPage() {
        view.switchView(1);
        return true;
    }

    // Handle down button - switch view
    function onPreviousPage() {
        view.switchView(-1);
        return true;
    }

    // Handle select button
    function onSelect() {
        // Could be used for lap marking or other features
        return true;
    }
}

// Delegate to handle save/discard confirmation
class SaveConfirmationDelegate extends WatchUi.ConfirmationDelegate {
    var view;

    function initialize(dragonBoatView) {
        ConfirmationDelegate.initialize();
        view = dragonBoatView;
    }

    function onResponse(response) {
        var model = view.getModel();

        if (response == WatchUi.CONFIRM_YES) {
            // Save the activity
            model.stopSession();
            System.println("Activity saved");
        } else {
            // Discard the activity
            model.discardSession();
            System.println("Activity discarded");
        }

        // Exit the app
        WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
        System.exit();
    }
}
