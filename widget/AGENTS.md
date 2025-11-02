# Project Context
HassControl is a Connect IQ widget for Garmin devices that interfaces with Home Assistant, a popular open-source home automation platform. The app enables users to control their home automation entities (lights, switches, sensors, etc.) directly from their Garmin watch, making it easier to control their smart home without using a phone or voice assistant.

The widget supports various Home Assistant entity types and handles both OAuth and long-lived token authentication methods. It's designed to be battery-efficient and compatible with a range of Garmin devices.

# Code Structure - Core Modules
- `App.mc`: Main application entry point, handles initialization and view management
- `ViewController.mc`: Manages transitions between different views (EntityView, SceneView, etc.)
- `hass/Client.mc`: Handles API communication with Home Assistant
- `hass/Hass.mc`: Core module with entity management functionality
- `hass/Entity.mc`: Entity class representing Home Assistant entities
- `hass/Constants.mc`: Constants for entity types, states, and errors
- `hass/OAuthClient.mc`: Handles OAuth authentication flow
- `hass/OauthCredentials.mc`: Manages storage and retrieval of authentication tokens

# Code Style Guidelines

## General
- Use Monkey C conventions and patterns
- Maintain consistent 2-space indentation
- Place opening braces on the same line as statements
- Use camelCase for variables and methods
- Prefix private/hidden variables with underscore (_variableName)
- Use class prefix for enums and constants (e.g., `HASS_STATE_ON`, `ERROR_NOT_AUTHORIZED`)

## Classes and Modules
- Place class methods in Monkey C modules with clear responsibilities
- Use the `:glance` annotation for code that can run in Garmin's glance mode
- Initialize all instance variables in the constructor
- Follow established naming patterns for consistency

## Comments
- Add comments for complex logic or non-obvious behavior
- Use function header comments to explain purpose, parameters, and return values
- Include `// TODO:` comments for incomplete implementations
- Document any workarounds for Connect IQ platform limitations

# Entity Implementation

## Entity Types
HassControl supports the following entity types:
- `TYPE_LIGHT`: Lights (on/off only)
- `TYPE_SWITCH`: Switches (on/off only)
- `TYPE_COVER`: Cover entities (open/close)
- `TYPE_LOCK`: Lock entities (lock/unlock)
- `TYPE_FAN`: Fan entities (on/off only)
- `TYPE_SCENE`: Scene activation
- `TYPE_SCRIPT`: Script activation
- `TYPE_AUTOMATION`: Automation toggle
- `TYPE_VALVE`: Valve entities (open/close)
- `TYPE_BINARY_SENSOR`: Read-only binary sensors
- `TYPE_INPUT_BOOLEAN`: Toggle boolean entities
- `TYPE_BUTTON`: Button entities that can be pressed
- `TYPE_INPUT_BUTTON`: Input button entities
- `TYPE_SENSOR`: Sensors with values (temperature, humidity, etc.)

## Entity States
Entities can be in various states:
- Basic states: `STATE_ON`, `STATE_OFF`, `STATE_UNKNOWN`
- Lock states: `STATE_LOCKED`, `STATE_UNLOCKED`, `STATE_LOCKING`, `STATE_UNLOCKING`
- Cover states: `STATE_OPEN`, `STATE_CLOSED`, `STATE_OPENING`, `STATE_CLOSING`
- Sensor state: `STATE_SENSOR` (with associated value)

## Adding New Entity Types
When adding a new entity type:
1. Add type constants in `hass/Constants.mc`
2. Update entity identification in `Entity.initialize()`
3. Add appropriate drawable resources in `resources/drawables/`
4. Implement state handling in `toggleEntityState()` method in `hass/Hass.mc`
5. Add icon handling in `EntityListView.getDrawableForEntity()`

# Error Handling
- Use the established error object patterns (`Error`, `RequestError`, `OAuthError`)
- Always check for null values before accessing object properties
- Use try/catch blocks for operations that may fail
- Implement proper error display to the user with contextual information
- Handle network errors and authentication failures gracefully

# Performance Considerations
- Minimize API calls to preserve battery life (Garmin watches have limited battery)
- Cache entities and other data whenever possible using `App.Storage`
- Use timers judiciously to avoid excessive battery drain
- Set appropriate refresh intervals for transitional states
- Clean up resources (especially timers) when views are hidden or app is closed
- Prefer batch operations over multiple individual API calls

# UI Guidelines
- Support both touch and button-based navigation for different Garmin models
- Ensure text is readable on small watch screens (limit text length)
- Use appropriate icons from the `resources/drawables` folder
- Follow Garmin's UI patterns for consistency with the platform
- Support Garmin's glance mode for quick information display
- Implement proper loading indicators for network operations

# Authentication
- Support both OAuth and long-lived token authentication methods
- OAuth flow: Handle authorization, token retrieval, refresh, and expiration
- Long-lived token: Store securely and use for API requests
- Validate connectivity and settings before attempting API calls
- Store credentials securely using Garmin's storage API
- Handle token revocation and auth errors properly
- Support additional HTTP headers for advanced authentication scenarios

# Sync and Data Management
- Use efficient entity synchronization with Home Assistant
- Support group-based entity import from Home Assistant
- Handle transitional states with appropriate refresh timers
- Store entities for offline access
- Implement proper battery reporting to Home Assistant
- Cache entity states to minimize network traffic
