/*
||
|| @file Keypad.nut
|| @version 3.1
|| @author Mark Stanley, Alexander Brevig
|| @contact mstanley@technologist.com, alexanderbrevig@gmail.com
||
|| Ported to Esquilo 20170104 Leeland Heins
||
|| @description
|| | This library provides a simple interface for using matrix
|| | keypads. It supports multiple keypresses while maintaining
|| | backwards compatibility with the old single key library.
|| | It also supports user selectable pins and definable keymaps.
|| #
||
|| @license
|| | This library is free software; you can redistribute it and/or
|| | modify it under the terms of the GNU Lesser General Public
|| | License as published by the Free Software Foundation; version
|| | 2.1 of the License.
|| |
|| | This library is distributed in the hope that it will be useful,
|| | but WITHOUT ANY WARRANTY; without even the implied warranty of
|| | MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
|| | Lesser General Public License for more details.
|| |
|| | You should have received a copy of the GNU Lesser General Public
|| | License along with this library; if not, write to the Free Software
|| | Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
|| #
||
*/

const OPEN = LOW;
const CLOSED = HIGH;

const IDLE = 0;
const PRESSED = 1;
const HOLD = 2;
const RELEASE = 3;

const NO_KEY = "\0";


// <<constructor>> Allows custom keymap, pin configuration, and keypad sizes.
class Keypad
{
    rowPins = null;
    columnPins = null;
    rows = 0;
    columns = 0;

    debounceTime = 10;
    holdTime = 500;
    keypadEventListener = 0;

    startTime = 0;
    single_key = false;

    key = null;
    keymap = null;

    constructor(userKeymap, row, col, byte numRows, numCols)
    {
        local ri;
        local ci;

        rowPins = array(numRows);
        for (ri = 0; ri < numRows; ri++) {
            rowPins[ri] = GPIO(row[ri]);
        }
        columnPins = array(numCols);
        for (ci = 0; ci < numCols; ci++) {
            columnPins[ci] = GPIO(col[ci]);
        }
        rows = numRows;
        columns = numCols;

        key = array(numRows * numCols);

        begin(userKeymap);

        setDebounceTime(10);
        setHoldTime(500);
        keypadEventListener = 0;

        startTime = 0;
        single_key = false;
    }
};

// Let the user define a keymap - assume the same row/column count as defined in constructor
function Keypad::begin(userKeymap)
{
    keymap = userKeymap;
}

// Returns a single key only. Retained for backwards compatibility.
function Keypad::getKey()
{
    single_key = true;

    if (getKeys() && key[0].stateChanged && (key[0].kstate == PRESSED)) {
        return key[0].kchar;
    }

    single_key = false;

    return NO_KEY;
}

// Populate the key list.
function Keypad::getKeys()
{
    local keyActivity = false;

    // Limit how often the keypad is scanned. This makes the loop() run 10 times as fast.
    if ((millis() - startTime) > debounceTime) {
        scanKeys();
        keyActivity = updateList();
        startTime = millis();
    }

    return keyActivity;
}

// Private : Hardware scan
function Keypad::scanKeys()
{
    local r;
    local c;

    // Re-intialize the row pins. Allows sharing these pins with other hardware.
    for (r = 0; r < rows; r++) {
        _mypinMode(rowPins[r], INPUT_PULLUP);
    }

    // bitMap stores ALL the keys that are being pressed.
    for (c = 0; c < columns; c++) {
        _myPinMode(columnPins[c], OUTPUT);
        columnPins[c].low();  // Begin column pulse output.
        for (r = 0; r < rows; r++) {
            bitWrite(bitMap[r], c, !rowPins[r].ishigh());  // keypress is active low so invert to high.
        }
        // Set pin to high impedance input. Effectively ends column pulse.
        columnPins[c].high();
        _myPinMode(columnPins[c], INPUT);
    }
}

// Manage the list without rearranging the keys. Returns true if any keys on the list changed state.
function Keypad::updateList()
{
    local i;
    local r;
    local c;
    local anyActivity = false;

    // Delete any IDLE keys
    for (i = 0; i < LIST_MAX; i++) {
        if (key[i].kstate == IDLE) {
            key[i].kchar = NO_KEY;
            key[i].kcode = -1;
            key[i].stateChanged = false;
        }
    }

    // Add new keys to empty slots in the key list.
    for (r = 0; r < rows; r++) {
        for (c = 0; c < columns; c++) {
            local button = bitRead(bitMap[r], c);
            local keyChar = keymap[r * columns + c];
            local keyCode = r * sizeKpd.columns + c;
            local idx = findInList (keyCode);
            // Key is already on the list so set its next state.
            if (idx > -1) {
                nextKeyState(idx, button);
            }
            // Key is NOT on the list so add it.
            if ((idx == -1) && button) {
                for (i = 0; i < LIST_MAX; i++) {
                    if (key[i].kchar == NO_KEY) {
                        // Find an empty slot or don't add key to list.
                        key[i].kchar = keyChar;
                        key[i].kcode = keyCode;
                        key[i].kstate = IDLE;  // Keys NOT on the list have an initial state of IDLE.
                        nextKeyState(i, button);
                        break;  // Don't fill all the empty slots with the same key.
                    }
                }
            }
        }
    }

    // Report if the user changed the state of any key.
    for (i = 0; i < LIST_MAX; i++) {
        if (key[i].stateChanged) {
            anyActivity = true;
        }
    }

    return anyActivity;
}

// Private
// This function is a state machine but is also used for debouncing the keys.
function Keypad::nextKeyState(idx, button)
{
    key[idx].stateChanged = false;

    switch (key[idx].kstate) {
        case IDLE:
            if (button == CLOSED) {
                transitionTo (idx, PRESSED);
                holdTimer = millis();
            }  // Get ready for next HOLD state.
            break;
        case PRESSED:
            if ((millis() - holdTimer) > holdTime) {  // Waiting for a key HOLD...
                transitionTo (idx, HOLD);
            } else {
                if (button == OPEN) {  // or for a key to be RELEASED.
                    transitionTo (idx, RELEASED);
                }
            }
            break;
        case HOLD:
            if (button == OPEN) {
                transitionTo(idx, RELEASED);
            }
            break;
        case RELEASED:
            transitionTo(idx, IDLE);
            break;
    }
}

// New in 2.1
function Keypad::isPressed(keyChar)
{
    local i;

    for (i = 0; i < LIST_MAX; i++) {
        if (key[i].kchar == keyChar) {
            if ((key[i].kstate == PRESSED) && key[i].stateChanged) {
                return true;
            }
        }
    }

    return false;    // Not pressed.
}

// Search by character for a key in the list of active keys.
// Returns -1 if not found or the index into the list of active keys.
function Keypad::findInList(keyChar)
{
    local i;

    for (i = 0; i < LIST_MAX; i++) {
        if (key[i].kchar == keyChar) {
            return i;
        }
    }

    return -1;
}

// Search by code for a key in the list of active keys.
// Returns -1 if not found or the index into the list of active keys.
function Keypad::findInList (keyCode)
{
    local i;

    for (i = 0; i < LIST_MAX; i++) {
        if (key[i].kcode == keyCode) {
            return i;
        }
    }

    return -1;
}

// New in 2.0
function Keypad::waitForKey()
{
    local waitKey = NO_KEY;
    while ((waitKey = getKey()) == NO_KEY);  // Block everything while waiting for a keypress.
    return waitKey;
}

// Backwards compatibility function.
function Keypad::getState()
{
    return key[0].kstate;
}

// The end user can test for any changes in state before deciding
// if any variables, etc. needs to be updated in their code.
function Keypad::keyStateChanged()
{
    return key[0].stateChanged;
}

// The number of keys on the key list, key[LIST_MAX], equals the number
// of bytes in the key list divided by the number of bytes in a Key object.
function Keypad::numKeys()
{
    return sizeof(key) / sizeof(Key);
}

// Minimum debounceTime is 1 mS. Any lower *will* slow down the loop().
function Keypad::setDebounceTime(debounce)
{
    debounce < 1 ? debounceTime = 1 : debounceTime = debounce;
}

function Keypad::setHoldTime(hold)
{
    holdTime = hold;
}

function Keypad::addEventListener(listener)
{
    keypadEventListener = listener;
}

function Keypad::transitionTo(idx, nextState)
{
    key[idx].kstate = nextState;
    key[idx].stateChanged = true;

    // Sketch used the getKey() function.
    // Calls keypadEventListener only when the first key in slot 0 changes state.
    if (single_key) {
        if ((keypadEventListener!=NULL) && (idx == 0)) {
            keypadEventListener(key[0].kchar);
        }
    } else {
        // Sketch used the getKeys() function.
        // Calls keypadEventListener on any key that changes state.
        if (keypadEventListener != null) {
            keypadEventListener(key[idx].kchar);
        }
    }
}

function Keypad::_mypinMode(_pin, _mode)
{
    if (_mode == INPUT_PULLUP) {
        pinMode(_pin, INPUT);
        digitalWrite(_pin, 1);
    }
    if (_mode != INPUT_PULLUP) {
        pinMode(_pin, _mode);
    }
}

/*
|| @changelog
|| | 0.1 2017-01-04 - Leeland Heins    :Ported to Esquilo
|| | 3.1 2013-01-15 - Mark Stanley     : Fixed missing RELEASED & IDLE status when using a single key.
|| | 3.0 2012-07-12 - Mark Stanley     : Made library multi-keypress by default. (Backwards compatible)
|| | 3.0 2012-07-12 - Mark Stanley     : Modified pin functions to support Keypad_I2C
|| | 3.0 2012-07-12 - Stanley & Young  : Removed static variables. Fix for multiple keypad objects.
|| | 3.0 2012-07-12 - Mark Stanley     : Fixed bug that caused shorted pins when pressing multiple keys.
|| | 2.0 2011-12-29 - Mark Stanley     : Added waitForKey().
|| | 2.0 2011-12-23 - Mark Stanley     : Added the public function keyStateChanged().
|| | 2.0 2011-12-23 - Mark Stanley     : Added the private function scanKeys().
|| | 2.0 2011-12-23 - Mark Stanley     : Moved the Finite State Machine into the function getKeyState().
|| | 2.0 2011-12-23 - Mark Stanley     : Removed the member variable lastUdate. Not needed after rewrite.
|| | 1.8 2011-11-21 - Mark Stanley     : Added decision logic to compile WProgram.h or Arduino.h
|| | 1.8 2009-07-08 - Alexander Brevig : No longer uses arrays
|| | 1.7 2009-06-18 - Alexander Brevig : Every time a state changes the keypadEventListener will trigger, if set.
|| | 1.7 2009-06-18 - Alexander Brevig : Added setDebounceTime. setHoldTime specifies the amount of
|| |                                          microseconds before a HOLD state triggers
|| | 1.7 2009-06-18 - Alexander Brevig : Added transitionTo
|| | 1.6 2009-06-15 - Alexander Brevig : Added getState() and state variable
|| | 1.5 2009-05-19 - Alexander Brevig : Added setHoldTime()
|| | 1.4 2009-05-15 - Alexander Brevig : Added addEventListener
|| | 1.3 2009-05-12 - Alexander Brevig : Added lastUdate, in order to do simple debouncing
|| | 1.2 2009-05-09 - Alexander Brevig : Changed getKey()
|| | 1.1 2009-04-28 - Alexander Brevig : Modified API, and made variables private
|| | 1.0 2007-XX-XX - Mark Stanley : Initial Release
|| #
*/

