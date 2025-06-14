## HassControl

A garmin widget to interact with [Home Assistant](https://www.home-assistant.io/).


<img src="resources/screenshots/tactix_delta_1.png" height="250" />


The widget aims to be simplistic but still provide the most basic functionality, such as triggering scenes or toggling lights and switches.

Due to limitations by both Garmin and Apple/Android some setup steps will be more cumbersome than what I would have preferred.

Please read through the instructions below, I will try to guide you through the steps :)

- [HassControl](#hasscontrol)
  - [Prerequisites](#prerequisites)
  - [Supported entity types](#supported-entity-types)
  - [Installation](#installation)
  - [Configuration](#configuration)
  - [Logging in](#logging-in)
  - [Group sync](#group-sync)
  - [Navigation \& Controls](#navigation--controls)
  - [Header Authentication](#header-authentication)
  - [FAQ](#faq)
    - [Unknown error -300 - Self-Signed SSL Certificate](#unknown-error--300---self-signed-ssl-certificate)
    - [Error message: "Check settings, invalid url"](#error-message-check-settings-invalid-url)
    - [Some entities from my group are missing in my Garmin device](#some-entities-from-my-group-are-missing-in-my-garmin-device)
    - [Changed entity state doesn't show immediately in HassControl](#changed-entity-state-doesnt-show-immediately-in-hasscontrol)


### Prerequisites
In order to use this widget you need to have an Home Assistant instance accessible over https using an official SSL certificate (no self-signed).

As all communication from Garmin watches go thru the mobile device, you also need to have a paired mobile phone, and the Garmin Connect app needs to be running on that phone.

As soon as you get out of range from the phone or closes the app the widget will stop functioning.


### Supported entity types
Currently only following Home Assistant entities are supported:

Entity type | Note
--- | ---
binary_sensor | Only displays basic boolean state, device class is not supported.
input_boolean | Toggling of its state is supported.
light | Only turning on/off is supported, the rest like colour, brightness, etc. are not supported.
button | Push/Trigger a button
input_button | Push/Trigger an input button
lock | Both locking and unlocking are supported.
cover | Both closing and opening the cover is supported.
fan | Turning on and off is supported. Changing speed is not.
switch | Only turning on/off, energy consumption and standby mode are not supported.
automation* | Can be turned on/off.
scene* | Execution
script* | Execution
sensor | Display values for the following sensor types: temperature, humidity, CO2, PM10, PM25 (others will be displayed but won't have a proper icon)


\* marked are not entities in the true sense of the word, but why have two tables

### Installation
The easiest way to install the app is to download and install the [ConnectIQ app](https://support.garmin.com/en-US/?faq=mmm2rz2WBI3zbdFQYdiwX8) from Garmin on your smartphone.

Once you have the app installed on your paired phone you can browse for widget and find the app by name, [HassControl](https://apps.garmin.com/en-US/apps/3dce2242-473f-4f13-a6a9-299c3686611f).

### Configuration
Open the widget settings in the ConnectIQ app.
[How to Access the Settings of a Connect IQ App Using the Garmin Connect App](https://support.garmin.com/en-US/?faq=SPo0TFvhQO04O36Y5TYRh5)

**Host**: This should be the url to the Home Assistant instance you would like to control. Remember only https url is supported by Garmin.

**Long-Lived access token**: If you prefer generating an access token in Home Assistant instead of login in thru the garmin app you can paste your token here.

**Scenes**: Since scene names aren't that configurable in Home Assistant you can override the names in this box. Multiple overrides can be specified by separating them with a comma (,).

So for example; If you have the scene `scene.good_bye` and `scene.movie` the configuration string could look like this: `good_bye=Good Bye, movie=Movie`, or `good_bye, movie`.

You can also use this field to "import" scenes if you don't want to create a group in Home Assistant as described below.

**Group**: In this box you can write a single group from Home Assistant, this group can then be used from within the widget to import all entities contained in that group.

I will describe this procedure in more detail below.

***Note:*** *The default start view is filtered to scenes and will not show light, switches etc., the start view can be changed in the widget settings in your Garmin device.*

**Battery percentage reporting**

Configure an arbitrary entity name (a-z, 0-9, _) to which the battery status of the watch should be reported.
e.g., "venu2_battery" (**excluding** the "sensor." prefix)
The battery value is being sent to Home Assistant once - when the app is started.
The corresponding entity is created automatically (e.g., "sensor.venu2_battery").

***Optionally***, you can configure a dedicated entity **before** the first use:

```
- template
  - sensor:
      - name: My Garmin Device
        device_class: "battery"
        unit_of_measurement: "%"
        state: 0
        unique_id: MyGarminDevice123
```
Then enter the corresponding entity name in the ConnectIQ app settings (excluding the "sensor." prefix)
e.g., "my_garmin_device"

### Logging in
Once you have configured all settings in the ConnectIQ app, the next step will be to login.

***Note:*** *If you've setup the `Long-Lived access token` you should be logged in automatically and can skip to the next section.*

Since the watch doesn't have an suited interface for logging in to web pages, the login will be performed with the help of your paired smartphone.

Before you get started, make sure that you have installed and paired your watch in the [Garmin Connect](https://connect.garmin.com/start/) app.

If you don't have push notifications turned on, make sure the app is running before proceeding.

To login, simply open the widget and trigger any scene. Shortly after, you will see a sign in request on your smartphone. Complete the sign in process on your phone and return to the watch.

You should now be able to trigger your scenes.

If you don't have any scenes, you can login by pressing and holding on the screen (long press) or using the menu button on your watch and logging in from the widget menu.

If you don't see any login request on your phone. Restart the widget after you have opened the garmin Connect app and the watch has been connected.

If you are having problems logging in or if the widget is logged out frequently, you can also generate a `Long-Lived access token` for your user in Home Assistant and paste it to the Connect IQ settings. This will bypass the normal login flow and use that token to communicate with Home Assistant.


### Group sync
Due to the limitations of the watch, there is no really good way of listing and adding entities directly from the watch.
But the easiest way to add your entities is by [creating a new group](https://www.home-assistant.io/integrations/group/) in Home Assistant, and add all your entities there.

Your group configuration can look like this:
```
# Example configuration.yaml entry
group:
  garmin:
    name: Garmin
    entities:
      - light.bathroom
      - switch.tv
      - script.turn_lights_for_10_min
```
***Note***: *Remember after changing the configuration, you have to either reload the groups or restart the Home Assistant.*

Then write the id of the group you have just created (in our case `group.garmin`) into the ConnectIQ app widget settings as described [above](#configuration).

Once you have added the group into ConnectIQ app widget settings, open the widget on your Garmin device and access the menu (either by using a long press on the screen or pressing the menu button). Then go into `Settings` and select `Refresh entities`.
Once that is done, all entities added to that group in Home Assistant and supported by HassControl will be imported and available on the watch.

If you done some modification to the group in Home Assistant, you can at any time repeat this procedure to add, update or remove entities from your watch.

### Navigation & Controls

The widget is designed to be as simple as possible, but there are a few things to keep in mind.

- **Scrolling**: Depending on your watch model, you can scroll through the widget using the touchscreen or the up/down buttons. If your watch has a touchscreen, you can also use the swipe gesture to scroll.
- **Selecting an entity**: To select an entity, simply scroll to it and press the "Select" button (usually the middle button on the right side of the watch).
- **Toggling a switch or light**: To toggle a switch or light, select the entity and press the "Select" button again. The entity should now be toggled on or off.
- **Triggering a scene or script**: To trigger a scene or script, select the entity and press the "Select" button. The scene or script should now be executed.
- **Refreshing entities**: If you have made changes to your entities in Home Assistant and want to update the widget, you can select the "Refresh entities" option in the widget menu. This will reload all entities from Home Assistant.

HassControl also supports the following controls:

- **Single tap/press**: Toggle the current entity (turn lights on/off, activate scenes, etc.)
- **Menu button**: Open the menu
- **Long press**: Open the menu (alternative to using the menu button)
- **Swipe/Page buttons**: Navigate between entities

On touchscreen devices, the long press gesture provides a convenient way to access the menu without using the physical menu button.

### Header Authentication

Since `v1.5.0` it's possible to specify an arbitraty header in the settings.
It's being added to all requests from the ConnectIQ device.
This can serve for authentication - e.g., like available for Cloudflare: https://developers.cloudflare.com/workers/examples/auth-with-headers/

If you use Caddy, you can implement this in the following way:

```
my-home-assistant.com {
     @headerauth {
         header X-Custom-PSK MY-PRE-SHARED-KEY
     }
     handle @headerauth {
        reverse_proxy 192.168.0.1:8123 {
          header_up -X-Custom-PSK
          header_up X-Forwarded-Host {host}
        }
     }
     respond 403
 }
```

### FAQ

#### Unknown error -300 - Self-Signed SSL Certificate
Are you using a self-signed certificate? Unfortunately, this is not supported.
Importing your certificate on the phone only makes it available on the phone.
It would have to be added on the watch (which is - at least currently - not possible)
So having an "official" SSL certificate is currently a must-have.
You can get them either by using the Caddy config below or use Let's Encrypt directly or by buying a certificate - which have become quite cheap.

See also https://github.com/hatl/hasscontrol/issues/17 for further details.

```
home-assistant.mydomain.com {
    @internal {
        remote_ip 192.168.0.0/24
    }
    handle @internal {
        reverse_proxy 192.168.0.1:8123 {
        header_up X-Forwarded-Host {host}
      }
    }
    respond 403
}
```

#### Error message: "Check settings, invalid url"
Check if you are using correct url with `https` prefix, because only secure HTTPS communication is allowed. This limitation comes from Garmin.

#### Some entities from my group are missing in my Garmin device
Not all Home Assistant entity types are currently supported by HassControl, you should take a look at [supported entity types table](#supported-entity-types).

#### Changed entity state doesn't show immediately in HassControl
There is a rare occasion when someone changes state of an entity (for example turns the light on), while you are actively using this widget. In this case its state in your Garmin device will not correspond to its actual one. It has to be synced again. There are three option how to sync it. You either toggle it's state, select `Refresh entities` in `Settings` or reopen the widget (the state of all your entities is automatically received from Home Assistant every time you start the widget).

***Note***: *Because after predefined timeout period every widget is automatically closed, you should never experience this type of data discrepancy.*

