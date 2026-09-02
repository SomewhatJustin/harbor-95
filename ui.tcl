#!/usr/bin/env wish

# PROTOTYPE: Harbor 95 — a Tk 9 shell around the real Harbor Node SDK.

set ::request_id 0
set ::bridge ""
set ::busy 1
set ::identity "NO IDENTITY"
set ::servers ""
set ::status "Starting SDK..."
set ::post_count 0
set ::image_paths {}
set ::app_dir [file dirname [file normalize [info script]]]

proc b64encode {value} {
    return [binary encode base64 -maxlen 0 [encoding convertto utf-8 $value]]
}

proc b64decode {value} {
    if {$value eq ""} { return "" }
    return [encoding convertfrom utf-8 [binary decode base64 $value]]
}

proc json_string_field {line key} {
    set expression [format {"%s":"([^"]*)"} $key]
    if {[regexp $expression $line _ value]} { return $value }
    return ""
}

proc json_number_field {line key} {
    set expression [format {"%s":([0-9]+)} $key]
    if {[regexp $expression $line _ value]} { return $value }
    return 0
}

proc send_command {action {text ""} {image_paths {}}} {
    if {$::bridge eq ""} { return }
    incr ::request_id
    set encoded [b64encode $text]
    set encoded_paths [join [lmap path $image_paths {b64encode $path}] ,]
    puts $::bridge [format \
        {{"id":%d,"action":"%s","textB64":"%s","imagePathsB64":"%s"}} \
        $::request_id $action $encoded $encoded_paths]
    flush $::bridge
    set ::busy 1
    .toolbar configure -cursor watch
}

proc set_status {message} {
    set ::status $message
    .status.message configure -text $message
}

proc render_state {} {
    set short_identity $::identity
    if {[string length $short_identity] > 25} {
        set short_identity "[string range $short_identity 0 24]..."
    }
    .identity.value configure -text $short_identity
    .identity.server configure -text "SERVER: $::servers"
}

proc clear_feed {} {
    set ::post_count 0
    .main.feed configure -state normal
    .main.feed delete 1.0 end
    .main.feed configure -state disabled
}

proc add_post {author created text images} {
    incr ::post_count
    set short_author $author
    if {[string length $short_author] > 18} {
        set short_author "[string range $short_author 0 17]..."
    }
    .main.feed configure -state normal
    .main.feed insert end "#$::post_count  $short_author" author
    .main.feed insert end "  $created\n" date
    .main.feed insert end "$text\n" body
    foreach image [split $images "\n"] {
        if {$image ne ""} {
            .main.feed insert end "IMAGE: $image\n" image
        }
    }
    .main.feed insert end \
        "  ☞ REPLY     ★ FAVORITE     ↻ REBROADCAST\n" actions
    .main.feed insert end \
        "__________________________________________________________________\n" rule
    .main.feed configure -state disabled
}

proc handle_bridge_line {line} {
    set type [json_string_field $line type]
    set ok [expr {[string first {"ok":true} $line] >= 0}]

    if {!$ok} {
        set message [b64decode [json_string_field $line messageB64]]
        set_status "ERROR: $message"
        set ::busy 0
        .toolbar configure -cursor ""
        if {[winfo exists .pair.actions.submit]} {
            .pair.actions.submit configure -state normal
            .pair.code configure -state normal
            .pair.progress configure -text $message
        }
        bell
        return
    }

    switch -- $type {
        ready {
            set_status [b64decode [json_string_field $line messageB64]]
            send_command state
        }
        state {
            set ::identity [b64decode [json_string_field $line identityB64]]
            set ::servers [b64decode [json_string_field $line serversB64]]
            set_status [b64decode [json_string_field $line messageB64]]
            render_state
        }
        feed_start {
            clear_feed
            set_status "Refreshing feed..."
        }
        feed_item {
            add_post \
                [b64decode [json_string_field $line authorB64]] \
                [b64decode [json_string_field $line createdAtB64]] \
                [b64decode [json_string_field $line textB64]] \
                [b64decode [json_string_field $line imagesB64]]
        }
        feed_end {
            set notice [b64decode [json_string_field $line messageB64]]
            if {$::post_count == 0} {
                .main.feed configure -state normal
                .main.feed insert end \
                    "NO POSTS AVAILABLE.\n\nCreate or pair an identity to begin." empty
                .main.feed configure -state disabled
            }
            if {$notice eq ""} {
                set_status "Feed ready: $::post_count post(s)."
            } else {
                set_status "Local feed ready; remote refresh failed: $notice"
            }
            set ::busy 0
            .toolbar configure -cursor ""
        }
        pairing_progress {
            set message [b64decode [json_string_field $line messageB64]]
            set_status $message
            if {[winfo exists .pair.progress]} {
                .pair.progress configure -text $message
            }
        }
        pairing_complete {
            set message [b64decode [json_string_field $line messageB64]]
            set_status $message
            if {[winfo exists .pair]} { destroy .pair }
        }
        post_complete {
            set message [b64decode [json_string_field $line messageB64]]
            .composer.text delete 1.0 end
            set ::image_paths {}
            render_attachments
            set_status $message
        }
        goodbye { destroy . }
    }
}

proc bridge_readable {} {
    if {[eof $::bridge]} {
        catch {close $::bridge}
        set ::bridge ""
        set_status "SDK PROCESS EXITED — inspect the launching terminal."
        .toolbar configure -cursor pirate
        bell
        return
    }
    while {[gets $::bridge line] >= 0} {
        handle_bridge_line $line
    }
}

proc create_identity {} {
    if {$::identity ne "NO IDENTITY"} {
        set_status "An identity is already active."
        bell
        return
    }
    set_status "Creating identity..."
    send_command bootstrap
}

proc transmit_post {} {
    set text [string trim [.composer.text get 1.0 end]]
    if {$text eq "" && [llength $::image_paths] == 0} {
        set_status "Add text or at least one image before publishing."
        bell
        return
    }
    set_status "Publishing post..."
    send_command create_post $text $::image_paths
}

proc render_attachments {} {
    set count [llength $::image_paths]
    if {$count == 0} {
        .composer.attachments configure -text "No images attached"
        return
    }
    set names [lmap path $::image_paths {file tail $path}]
    .composer.attachments configure -text "$count image(s): [join $names {, }]"
}

proc choose_images {} {
    set selected [tk_getOpenFile -title "Attach Images" -multiple true \
        -filetypes {
            {{Image files} {.jpg .jpeg .png .gif .webp .bmp}}
            {{All files} *}
        }]
    if {$selected eq ""} { return }
    set ::image_paths [lrange $selected 0 3]
    render_attachments
    if {[llength $selected] > 4} {
        set_status "Only the first four selected images were attached."
    }
}

proc refresh_feed {} {
    set_status "Refreshing feed..."
    send_command refresh
}

proc sync_feed {} {
    set_status "Synchronizing..."
    send_command sync
}

proc submit_pairing {} {
    set code [string trim [.pair.code get 1.0 end]]
    if {$code eq ""} {
        .pair.progress configure -text "Paste a pairing code to continue."
        bell
        return
    }
    .pair.actions.submit configure -state disabled
    .pair.code configure -state disabled
    .pair.progress configure -text "Joining pairing session..."
    send_command pair_identity $code
}

proc open_pair_dialog {} {
    if {[winfo exists .pair]} {
        raise .pair
        focus .pair.code
        return
    }

    toplevel .pair
    wm title .pair "Pair Identity"
    wm transient .pair .
    wm geometry .pair 620x360
    label .pair.title -text "PAIR IDENTITY" -font {Helvetica 15 bold} \
        -background #000080 -foreground white -anchor w -padx 10 -pady 8
    label .pair.instructions -text \
        "In Harbor Web, open Settings > Pair Identity, create a pairing session, and copy its pairing code here." \
        -wraplength 570 -justify left -anchor w -padx 12 -pady 12
    label .pair.label -text "PAIRING CODE" -font {Helvetica 9 bold} -anchor w
    text .pair.code -height 8 -wrap char -font {Courier 9} -background white \
        -relief sunken -borderwidth 2
    label .pair.progress -text "" -font {Helvetica 9} -anchor w -foreground #000080
    frame .pair.actions
    button .pair.actions.cancel -text "CANCEL" -command {destroy .pair} -padx 14
    button .pair.actions.submit -text "CONTINUE" -font {Helvetica 10 bold} \
        -command submit_pairing -padx 14
    pack .pair.title -side top -fill x
    pack .pair.instructions -side top -fill x
    pack .pair.label -side top -fill x -padx 12
    pack .pair.actions.submit .pair.actions.cancel -side right -padx 8 -pady 10
    pack .pair.actions -side bottom -fill x
    pack .pair.progress -side bottom -fill x -padx 12 -pady 4
    pack .pair.code -side top -fill both -expand 1 -padx 12 -pady 4
    bind .pair <Control-Return> {submit_pairing}
    focus .pair.code
}

proc shutdown {} {
    if {$::bridge ne ""} {
        catch {send_command shutdown}
        after 150
    }
    destroy .
}

wm title . "Harbor 95 — Polycentric Client"
wm geometry . 980x720
wm minsize . 760 560
wm protocol . WM_DELETE_WINDOW shutdown
option add *Font {Helvetica 10}
option add *Background #c0c0c0
option add *activeBackground #dfdfdf

menu .menubar -relief raised -borderwidth 2
. configure -menu .menubar
foreach label {File Edit View Sync Identity Help} {
    set menu_name [string tolower $label]
    menu .menubar.$menu_name -tearoff 0
    .menubar add cascade -label $label -menu .menubar.$menu_name
}
.menubar.file add command -label "Exit" -command shutdown
.menubar.edit add command -label "Copy" -command {event generate [focus] <<Copy>>}
.menubar.view add command -label "Refresh Feed" -accelerator F5 -command refresh_feed
.menubar.sync add command -label "Synchronize Now" -command sync_feed
.menubar.identity add command -label "Create Identity" -command create_identity
.menubar.identity add command -label "Pair Existing Identity" -command open_pair_dialog
.menubar.help add command -label "About" -command {
    tk_messageBox -title "About Harbor 95" -message \
        "Harbor 95 Prototype\n\nA Tcl/Tk desktop interface backed by Harbor's Node and Rust/WASM SDK."
}

frame .masthead -relief raised -borderwidth 3 -background #000080
label .masthead.title -text "HARBOR 95" -font {Helvetica 22 bold} \
    -foreground white -background #000080 -padx 12 -pady 8
label .masthead.subtitle -text "POLYCENTRIC CLIENT" \
    -font {Helvetica 9 bold} -foreground #ffff00 -background #000080
pack .masthead.title -side left
pack .masthead.subtitle -side right -padx 14
pack .masthead -side top -fill x

frame .toolbar -relief raised -borderwidth 2
button .toolbar.identity -text "CREATE IDENTITY" -command create_identity -padx 10
button .toolbar.pair -text "PAIR IDENTITY" -command open_pair_dialog -padx 10
button .toolbar.refresh -text "REFRESH" -command refresh_feed -padx 10
button .toolbar.sync -text "SYNC" -command sync_feed -padx 10
button .toolbar.about -text "? ABOUT" -command {.menubar.help invoke 0} -padx 10
pack .toolbar.identity .toolbar.pair .toolbar.refresh .toolbar.sync .toolbar.about \
    -side left -padx 3 -pady 3
pack .toolbar -side top -fill x

frame .identity -relief groove -borderwidth 2
label .identity.label -text "ACTIVE IDENTITY:" -font {Helvetica 9 bold}
label .identity.value -text $::identity -font {Courier 10 bold} -foreground #000080
label .identity.server -text "SERVER:" -font {Courier 9}
pack .identity.label .identity.value -side left -padx 6 -pady 5
pack .identity.server -side right -padx 8
pack .identity -side top -fill x -padx 7 -pady 5

frame .nav -relief sunken -borderwidth 2 -width 175
label .nav.heading -text "NAVIGATION" -font {Helvetica 10 bold} \
    -background #000080 -foreground white -anchor w -padx 6 -pady 4
listbox .nav.list -relief flat -highlightthickness 0 -exportselection false \
    -font {Helvetica 11} -width 21 -height 10
foreach item {"  Home" "  Global Feed" "  Search" "  Profile" "  Media" "  Settings"} {
    .nav.list insert end $item
}
.nav.list selection set 1
label .nav.warning -text "PROTOTYPE\nBUILD" \
    -font {Helvetica 9 bold} -foreground #800000 -relief ridge -borderwidth 2 -pady 8
pack .nav.heading -side top -fill x
pack .nav.list -side top -fill both -expand 1
pack .nav.warning -side bottom -fill x -padx 7 -pady 7

frame .main -relief sunken -borderwidth 2
label .main.heading -text "LATEST POSTS" -font {Helvetica 12 bold} \
    -anchor w -background #008080 -foreground white -padx 8 -pady 5
scrollbar .main.scroll -command {.main.feed yview}
text .main.feed -yscrollcommand {.main.scroll set} -wrap word -state disabled \
    -font {Times 12} -background white -foreground black -padx 14 -pady 10 \
    -relief flat -borderwidth 0
.main.feed tag configure author -font {Helvetica 10 bold} -foreground #000080
.main.feed tag configure date -font {Helvetica 8} -foreground #606060
.main.feed tag configure body -font {Times 13} -spacing1 7 -spacing3 7
.main.feed tag configure image -font {Courier 8 underline} -foreground #0000cc
.main.feed tag configure actions -font {Courier 8 bold} -foreground #008080
.main.feed tag configure rule -foreground #a0a0a0
.main.feed tag configure empty -font {Courier 12 bold} -foreground #808080 -justify center -spacing1 30
pack .main.heading -side top -fill x
pack .main.scroll -side right -fill y
pack .main.feed -side left -fill both -expand 1

frame .composer -relief raised -borderwidth 3
label .composer.label -text "NEW POST:" -font {Helvetica 9 bold}
text .composer.text -height 3 -wrap word -font {Courier 11} -background white \
    -relief sunken -borderwidth 2
label .composer.attachments -text "No images attached" -font {Helvetica 9} \
    -anchor w -foreground #505050
button .composer.attach -text "ATTACH IMAGES" -command choose_images -padx 10
button .composer.send -text "PUBLISH" -font {Helvetica 10 bold} \
    -command transmit_post -padx 16 -pady 8
pack .composer.label -side top -anchor w -padx 7 -pady {5 2}
pack .composer.send -side right -padx 7 -pady 6 -fill y
pack .composer.attach -side right -padx 3 -pady 6 -fill y
pack .composer.attachments -side bottom -fill x -padx 7 -pady {0 5}
pack .composer.text -side left -fill both -expand 1 -padx {7 2} -pady {2 3}

frame .status -relief sunken -borderwidth 2
label .status.message -text $::status -anchor w -font {Courier 9} -padx 5
label .status.protocol -text "NDJSON | Tcl/Tk 9 | WASM" -relief sunken \
    -borderwidth 1 -font {Courier 8 bold} -padx 8
pack .status.message -side left -fill x -expand 1
pack .status.protocol -side right
pack .status -side bottom -fill x
pack .composer -side bottom -fill x -padx 7 -pady {0 5}
pack .nav -side left -fill y -padx {7 4} -pady {2 6}
pack .main -side left -fill both -expand 1 -padx {4 7} -pady {2 6}

bind . <F5> {refresh_feed}
bind . <Control-Return> {transmit_post}
focus .composer.text

set bridge_script [file join $::app_dir src bridge.ts]
if {[catch {
    set ::bridge [open |[list tsx $bridge_script] r+]
    fconfigure $::bridge -blocking false -buffering line -encoding utf-8
    fileevent $::bridge readable bridge_readable
} error]} {
    set_status "FAILED TO START SDK: $error"
    tk_messageBox -icon error -title "Harbor 95 startup failure" -message $error
}
