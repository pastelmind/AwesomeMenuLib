/**
 * awesome-menu-lib is a script for manipulating the top menu bar icons.
 * For command line usage, type in "awesome-menu-lib help" in the gCLI.
 */

script "awesome-menu-lib";
notify "philmasterplus";
since 20.7;


//-------- Utility functions for internal use --------//

/**
 * Attempt to unescape the raw content of a HTML attribute.
 * @param text String from HTML attribute
 * @return Unescaped string
 */
string _unescape_attr(string text) {
  // Unescape entities twice because KoL escapes them twice in the raw HTML
  return entity_decode(entity_decode(text)).replace_string("\\/", "/");
}

//-------- Low-level methods --------//

/**
 * Represents a single Awesome Menu icon
 */
record AwesomeMenuIcon {
  /** Icon file name without the extension. */
  string icon;
  /**
   * Usually, either "go" or "macro". Empty icons have "".
   * When the top menu is reset, the Donate button will have "popup" as its
   * actiontype.
   */
  string actiontype;
  /**
   * URL to visit for "go" actions. If the actiontype is "macro", the game will
   * ignore this field.
   */
  string go;
  /** Chat macro to execute for "macro" actions. */
  string macro;
  /**
   * Name shown when you hover the cursor over the icon, or in Text Mode.
   * If the actiontype is "go" or "popup", the game appears to ignore this
   * field.
   */
  string name;
};

/**
 * Represents a single row of an Awesome Menu.
 * Each row has a unique "Y key" number, which is usually (but NOT necessarily)
 * equal to the row index. Don't ask me why KoL works like this.
 * Thankfully, cells don't have a "X key"--their column index is the "X key".
 */
record AwesomeMenuRow {
  /**
   * The Y key. This is usually (but NOT always) equal to the row index.
   */
  int y;
  /** Icons in this row, indexed by the X key. */
  AwesomeMenuIcon [int] icons;
};

/**
 * Represents an Awesome Menu.
 */
record AwesomeMenu {
  /**
   * Map of row index => AwesomeMenuRow records.
   * The row index is NOT necessarily the same as the Y key!
   */
  AwesomeMenuRow [int] rows;
};

/**
 * Return a string representing the Awesome Menu icon.
 * Primarily used for debugging.
 * @param {ai_icon} Awesome Menu icon record
 * @return String representation of the icon
 */
string to_string(AwesomeMenuIcon ai_icon) {
  return `\{actiontype="{ai_icon.actiontype}", go="{ai_icon.go}", macro="{ai_icon.macro}", name="{ai_icon.name}"\}`;
}

/**
 * Parses the given HTML and extract an Awesome Menu icon.
 * @param html HTML markup of the icon
 * @return AwesomeMenuIcon record
 */
AwesomeMenuIcon _parse_awesome_menu_icon(string html) {
  // data-def is of the form:
  //    [icon_name, "macro", macro, name], or
  //    [icon_name, "go", url, name], or
  //    [icon_name, "go", url]
  matcher def_matcher = create_matcher(
    '\\sdata-def="\\[&quot;([^"]*)&quot;\\]"', html
  );

  if (!def_matcher.find()) {
    abort(`Cannot find "data-def" attribute in {entity_encode(html)}`);
  }
  string [int] def = def_matcher.group(1).split_string("&quot;,&quot;");

  // icon and actiontype fields are mandatory, but other fields can be empty
  if (def.count() < 2) {
    abort(`"data-def" attribute does not have enough values in {entity_encode(html)}`);
  } else if (def.count() > 4) {
    abort(`"data-def" attribute has too many values in {entity_encode(html)}`);
  }

  string icon = def[0];
  string actiontype = def[1];
  string go_or_macro = def contains 2 ? _unescape_attr(def[2]) : "";
  string name = def contains 3 ? _unescape_attr(def[3]) : "";

  if (actiontype == "go" || actiontype == "popup") {
    return new AwesomeMenuIcon(icon, actiontype, go_or_macro, "", name);
  } else if (actiontype == "macro") {
    return new AwesomeMenuIcon(icon, actiontype, "", go_or_macro, name);
  } else {
    abort(`Invalid actiontype: "{actiontype}"`);
    // This statement is never reached, but added anyway to make KoLmafia happy
    return new AwesomeMenuIcon();
  }
}

/**
 * Parses the given HTML and extract an Awesome Menu Row.
 * @param html HTML markup of the row
 * @return AwesomeMenuRow record
 */
AwesomeMenuRow _parse_awesome_menu_row(string html) {
  AwesomeMenuRow row;
  boolean is_y_key_set = false;

  // Detect non-empty and empty icons alike, so that we can properly parse
  // Y-keys even if the entire row has only empty icons.
  matcher icon_elem_matcher = create_matcher(
    '<\\w+[^>]+?class="ai\\b[^>]*>', html
  );

  while (icon_elem_matcher.find()) {
    string elem = icon_elem_matcher.group();
    string elem_safe = entity_encode(elem);

    matcher xy_matcher = create_matcher('\\sdata-xy="(\\d+),(\\d+)"', elem);

    if (!xy_matcher.reset(elem).find()) {
      abort(`Cannot find "data-xy" attribute in {elem_safe}`);
    }
    int x = to_int(xy_matcher.group(1));
    int y_key = to_int(xy_matcher.group(2));
    if (y_key == -1) {
      abort(`Unexpected Y-key: Icon uses -1 as the Y-key in {elem_safe}`);
    }

    if (!is_y_key_set) {
      row.y = y_key;
      is_y_key_set = true;
    } else {
      // Sanity check
      if (row.y != y_key) {
        abort(`Unexpected Y-key: Icon has Y-key of {y_key}, but the row has {row.y} in {elem_safe}`);
      }
    }

    if (row.icons contains x) {
      abort(
        `Another icon is already occupying {x},{y_key} ({to_string(row.icons[x])})`
      );
    }

    // Skip empty icons
    if (!elem.contains_text("ai empty")) {
      row.icons[x] = _parse_awesome_menu_icon(elem);
    }
  }

  if (!is_y_key_set) {
    // This may happen if a row has no icons at all (not even empty ones).
    // Currently, KoL generates empty icons even for empty rows, so this
    // shouldn't happen...unless KoL changes.
    abort("Could not find a Y-key for the row.");
  }

  return row;
}

/**
 * Parses the given HTML and extract Awesome Menu icon information.
 * @param html HTML markup of awesomemenu.php
 * @return Map of (column index) => (AwesomeMenuRow record)
 */
AwesomeMenu parse_awesome_menu(string html) {
  AwesomeMenu awesome_menu;

  // Note: Don't use xpath() to extract data.
  // xpath() tries to unescapes HTML entities, but it does so in an inconsistent
  // way:
  //
  //    &amp;           ->  &
  //    &quot;          ->  "
  //    &amp;amp;       ->  &
  //    &amp;quot;      ->  "
  //    &amp;amp;amp;   ->  &amp;
  //    &amp;amp;quot;  ->  &quot;
  //
  // Using regular expressions to parse HTML is the second-to-worst thing I can
  // do. However, the only alternative is a broken xpath(). Sigh...
  matcher icon_row_matcher = create_matcher(
    '<div class="custom">([\\s\\S]*?</div>)</div>', html
  );

  while (icon_row_matcher.find()) {
    awesome_menu.rows[awesome_menu.rows.count()] = _parse_awesome_menu_row(
      icon_row_matcher.group(1)
    );
  }

  if (awesome_menu.rows.count() == 0) abort("Cannot detect Awesome Menu");
  return awesome_menu;
}

/**
 * Retrieves the current Awesome Menu configuration.
 * @return Current Awesome Menu configuration
 */
AwesomeMenu get_awesome_menu() {
  return parse_awesome_menu(visit_url("awesomemenu.php"));
}

/**
 * Creates a new icon and return the updated configuration.
 *
 * The game will place the new icon to the right of the right-most icon in the
 * bottom row.
 * @param ai_icon Awesome Menu icon to create
 * @return Updated Awesome Menu icon config
 */
AwesomeMenu create(AwesomeMenuIcon ai_icon) {
  buffer url;
  url.append(`awesomemenu.php`);
  url.append(`?existing=`); // Empty string
  url.append(`&actiontype={url_encode(ai_icon.actiontype)}`);
  url.append(`&icon={url_encode(ai_icon.icon)}`);
  url.append(`&go={url_encode(ai_icon.go)}`);
  url.append(`&macro={url_encode(ai_icon.macro)}`);
  url.append(`&name={url_encode(ai_icon.name)}`);

  return parse_awesome_menu(visit_url(url, true, true));
}

/**
 * Updates the icon at (x_key, y_key) and return the updated configuration.
 *
 *  - If a row with the given Y-key does not exist, the game will create a new
 *    row with the given Y-key, then add a new icon at (x_key, y_key).
 *    The game will not create additional rows to fill the gap (if it exists)
 *    between existing rows and the new row.
 *  - If a row with the given Y-key exists, but there is no icon at
 *    (x_key, y_key), the game will add a new icon at (x_key, y_key).
 * @param ai_icon Awesome Menu icon
 * @param x_key X-key of the icon to update
 * @param y_key Y-key of the icon to update
 * @return Updated Awesome Menu icon config
 */
AwesomeMenu update(AwesomeMenuIcon ai_icon, int x_key, int y_key) {
  buffer url;
  url.append(`awesomemenu.php`);
  url.append(`?existing={x_key},{y_key}`);
  url.append(`&actiontype={url_encode(ai_icon.actiontype)}`);
  url.append(`&icon={url_encode(ai_icon.icon)}`);
  url.append(`&go={url_encode(ai_icon.go)}`);
  url.append(`&macro={url_encode(ai_icon.macro)}`);
  url.append(`&name={url_encode(ai_icon.name)}`);

  return parse_awesome_menu(visit_url(url, true, true));
}

/**
 * Move the Awesome Menu icon at (old_x, old_y) to (new_x, new_y).
 * If another icon is already at (new_x, new_y), the two icons will swap
 * positions.
 * @param old_x Current X-key
 * @param old_y Current Y-key
 * @param new_x Target X-key
 * @param new_y Target Y-key
 * @return Updated Awesome Menu icon config
 */
AwesomeMenu move_icon(int old_x, int old_y, int new_x, int new_y) {
  buffer url;
  url.append(`awesomemenu.php?pwd`);
  url.append(`&action=drag`);
  url.append(`&s={old_x},{old_y}`);
  url.append(`&e={new_x},{new_y}`);

  return parse_awesome_menu(visit_url(url, true, true));
}

/**
 * Delete the Awesome Menu icon at (x_key, y_key).
 * @param x_key X-key
 * @param y_key Y-key
 * @return Updated Awesome Menu icon config
 */
AwesomeMenu delete_icon(int x_key, int y_key) {
  string url = `awesomemenu.php?pwd={my_hash()}&delete={x_key},{y_key}`;
  // The game uses a GET request for this operation
  // Also, don't encode the comma
  return parse_awesome_menu(visit_url(url, false, true));
}

/**
 * Resets the Awesome Menu configuration.
 * WARNING: This will destroy your current Awesome Menu configuration!
 * @return Awesome Menu configuration after the reset
 */
AwesomeMenu reset_awesome_menu() {
  return parse_awesome_menu(
    visit_url("awesomemenu.php?pwd&action=reset", true)
  );
}

record Point {
  int x;
  int y;
};

/**
 * Attempts to guess the offset where the game will create the next new icon
 * when `create()` is called.
 * @param awesome_menu Current Awesome Menu configuration
 * @return Point where the new icon will be created
 */
Point next_created_pos(AwesomeMenu awesome_menu) {
  if (awesome_menu.rows.count() == 0) return new Point(0, 0);

  int y_key_max = -4294967295;
  AwesomeMenuRow [int] rows_by_y_key;
  foreach _, row in awesome_menu.rows {
    rows_by_y_key[row.y] = row;
    y_key_max = max(y_key_max, row.y);
  }

  // Assumption:
  // The game starts at Y-key == 0 and explores downward.
  // If the game encounters a "missing" row, it will add the next icon to that
  // row.
  // Otherwise, the game will add the icon at the end of the row with the
  // highest Y-key.
  int y_key = 0;
  while (y_key < y_key_max) {
    if (!(rows_by_y_key contains y_key)) break;
    ++y_key;
  }

  int x_rightmost = -1;
  foreach x_key in rows_by_y_key[y_key].icons {
    x_rightmost = max(x_rightmost, x_key);
  }
  return new Point(x_rightmost + 1, y_key);
}

//-------- High-level methods --------//

/**
 * Applies the Awesome Menu configuration to your current Awesome Menu.
 * WARNING: This will destroy your current Awesome Menu!
 * @param config Awesome Menu configuration to apply
 */
void apply_awesome_menu(AwesomeMenu config) {
  // Reset the current menu to avoid complications with out-of-order configs
  print("Resetting Awesome Menu...");
  AwesomeMenu current = reset_awesome_menu();

  while (current.rows[0].icons.count() > 0) {
    foreach x, icon in current.rows[0].icons {
      current = delete_icon(x, current.rows[0].y);
    }
  }

  foreach row_index, row in config.rows {
    print(`Setting up row {row_index}...`);
    if (row.icons.count() == 0) {
      // If this row is empty...
      // The easiest way of creating an empty row is to swap an empty cell with
      // itself. Only one network request needed.
      move_icon(0, row.y, 0, row.y);
    } else {
      // If the row is not empty...
      // Create icons, one by one
      foreach x, icon in row.icons {
        update(icon, x, row.y);
      }
    }
  }
}

string PRESET_FILE = "awesome-menu-presets.txt";

//-------- Utility functions for main() --------//

/**
 * Saves Awesome Menu presets to a text file.
 * @param file Text file to write to
 * @param presets Awesome Menu preset data
 */
void save_awesome_menu_presets_to_file(string file, AwesomeMenu [string] presets) {
  if (!map_to_file(presets, file)) {
    abort(`Cannot save Awesome Menu preset file: {file}`);
  }
}

/**
 * Loads Awesome Menu presets from a text file.
 * @param file Text file to read from
 * @return Map of preset names to Awesome Menu presets
 */
AwesomeMenu [string] load_awesome_menu_presets_from_file(string file) {
  AwesomeMenu [string] presets;
  if (!file_to_map(file, presets)) {
    abort(`Cannot load Awesome Menu preset file: {file}`);
  }
  return presets;
}

/**
 * Splits a string containing tokens separated by whitespace.
 * More resilient than using `string_split(to_split, " ")`
 * @param to_split String to split
 * @return List of tokens
 */
string [int] _split_whitespace(string to_split) {
  string [int] result;
  matcher token_matcher = create_matcher("(\\S+)\\s*", to_split);
  while (token_matcher.find()) {
    result[result.count()] = token_matcher.group(1);
  }
  return result;
}

/**
 * Aborts the program if `args` does not contain exactly `arg_count` + 1 items.
 * @param args List of strings
 * @param arg_count Expected number of arguments
 */
void _expect_arg_count(string [int] args, int arg_count) {
  int actual_count = args.count() - 1;
  if (actual_count < arg_count) {
    abort(`Not enough arguments for command "{args[0]}" (expected {arg_count}, got {actual_count})`);
  } else if (actual_count > arg_count) {
    abort(`Too many arguments for command "{args[0]}" (expected {arg_count}, got {actual_count})`);
  }
}

/**
 * Entrypoint for the gCLI interface.
 * @param commands Commands
 */
void main(string commands) {
  string [int] args = _split_whitespace(commands);

  // Default command is help
  string cmd = args.count() == 0 ? "?" : args[0];

  // Print help and exit
  if (cmd == "?" || cmd == "help") {
    print_html("Usage: <b>awesome-menu-lib</b> help | ? | save <i>preset</i> | apply <i>preset</i>");
    return;
  } else if (cmd == "save") {
    _expect_arg_count(args, 1);
    string preset_name = args[1];

    AwesomeMenu [string] presets = load_awesome_menu_presets_from_file(PRESET_FILE);
    if (presets contains preset_name && !user_confirm(`{PRESET_FILE} already contains a preset named "{preset_name}".\nOverwrite?`)) {
      abort(`You choose not to overwrite the Awesome Menu preset named "{preset_name}".`);
    }
    presets[preset_name] = get_awesome_menu();

    save_awesome_menu_presets_to_file(PRESET_FILE, presets);
    print_html(`Saved current Awesome Menu configuration to <code>{PRESET_FILE}</code> under <code>"{preset_name}"</code>`);
  } else if (cmd == "apply") {
    _expect_arg_count(args, 1);
    string preset_name = args[1];

    AwesomeMenu [string] presets = load_awesome_menu_presets_from_file(PRESET_FILE);
    if (!(presets contains preset_name)) {
      abort(`Cannot find Awesome Menu preset named "{preset_name}" in {PRESET_FILE}`);
    }
    AwesomeMenu config = presets[preset_name];

    if (!user_confirm(`WARNING: This will overwrite your Awesome Menu configuration with the preset "{preset_name}". Before you continue, save your current preset with the command:\n\n> awesome-menu-lib save <preset_name>\n\nDo you want to continue?`)) {
      abort(`You choose not to change your Awesome Menu.`);
    }
    print(`Applying Awesome Menu configuration "{preset_name}"...`);
    apply_awesome_menu(config);
    print("Done! Enjoy your new Awesome Menu.");
  } else {
    abort(`Unknown command: {cmd}<br>Use <kbd>awesome-menu-lib help</kbd> to check usage`);
  }
}
