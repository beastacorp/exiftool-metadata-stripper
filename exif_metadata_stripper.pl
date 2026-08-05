#!/usr/bin/env perl
#------------------------------------------------------------------------------
# File:         exif_metadata_stripper.pl
#
# Description:  ExifTool Metadata Stripper -- a lightweight, removal-only
#               GUI front end for Image::ExifTool.
#
#               This tool intentionally does ONE thing: it deletes all
#               metadata from the files or folders you give it. There is
#               no tag editor, no tag "set" or "swap" capability, no batch
#               rename, and no format conversion. If you need any of that,
#               use the full "exiftool" command-line application that ships
#               alongside this tool -- this is meant to be the safe, fast,
#               "just get rid of it" utility.
#
# GUI:          Perl/Tk. Two ways to load files, both drag-and-drop-based
#               to match how the stock ExifTool Windows .exe already works:
#
#                 1. Drop files/folders onto the compiled .exe's icon in
#                    Explorer (or a shortcut to it). This is the exact same
#                    mechanism windows_exiftool.exe uses -- Windows passes
#                    the dropped paths in as @ARGV, no code of ours has to
#                    reimplement drag-and-drop handling.
#
#                 2. With the tool already open, use "Add Files..." /
#                    "Add Folder..." to browse for more.
#
#               Either way, nothing is touched on disk until you press
#               "Remove All Metadata" AND confirm the "Are you sure?"
#               prompt that follows.
#
# Usage:        perl exif_metadata_stripper.pl [file_or_folder ...]
#
# Requires:     Perl/Tk               (GUI)
#               Image::ExifTool       (bundled ../lib -- the full ExifTool
#                                      library tree, needed so every file
#                                      format ExifTool understands can be
#                                      stripped correctly)
#               ExifStripper::Core    (bundled ./lib -- see that module for
#                                      the actual removal logic; kept
#                                      separate from this file so it has no
#                                      GUI dependency and can be tested on
#                                      its own)
#
# Packaging:    Build a stand-alone Windows .exe with PAR::Packer from this
#               directory:
#                   pp @pp_build_exe.args
#               See pp_build_exe.args and README.md in this directory.
#------------------------------------------------------------------------------
use strict;
use warnings;

my $scriptDir;
BEGIN {
    $scriptDir = ($0 =~ /(.*)[\\\/]/) ? $1 : '.';
    # bundled full ExifTool library (sibling of this strip_tool directory)
    unshift @INC, "$scriptDir/../lib";
    # this tool's own core module
    unshift @INC, "$scriptDir/lib";
}

use Tk;
use Tk::Font;
use ExifStripper::Core qw(collect_files strip_files);

my $VERSION = '1.0';

#------------------------------------------------------------------------------
# state

my @queue;          # full paths of files currently queued (post folder-expansion)
my %queuedDirs;      # original folder paths added, just for display de-dup
my $running = 0;    # true while a strip pass is in progress

#------------------------------------------------------------------------------
# build the window

my $mw = MainWindow->new(-title => "ExifTool Metadata Stripper $VERSION");
$mw->geometry('720x480');
$mw->minsize(560, 380);

my $boldFont = $mw->fontCreate('StripperBold', -weight => 'bold', -size => 10);

# --- top: instructions -------------------------------------------------------
$mw->Label(
    -text => 'Add files or folders below, then remove all metadata from them. '
           . 'This tool only removes metadata -- it cannot edit, set, or swap tags.',
    -justify => 'left', -anchor => 'w', -wraplength => 700,
)->pack(-side => 'top', -fill => 'x', -padx => 10, -pady => [8, 2]);

# --- button bar ---------------------------------------------------------------
my $btnFrame = $mw->Frame->pack(-side => 'top', -fill => 'x', -padx => 10, -pady => 4);

my $addFilesBtn = $btnFrame->Button(
    -text => 'Add Files...', -width => 14, -command => \&add_files,
)->pack(-side => 'left', -padx => [0, 6]);

my $addFolderBtn = $btnFrame->Button(
    -text => 'Add Folder...', -width => 14, -command => \&add_folder,
)->pack(-side => 'left', -padx => [0, 6]);

my $removeSelBtn = $btnFrame->Button(
    -text => 'Remove Selected From List', -command => \&remove_selected,
)->pack(-side => 'left', -padx => [0, 6]);

my $clearBtn = $btnFrame->Button(
    -text => 'Clear List', -command => \&clear_list,
)->pack(-side => 'left');

# --- file list -----------------------------------------------------------------
my $listFrame = $mw->Frame->pack(-side => 'top', -fill => 'both', -expand => 1, -padx => 10, -pady => 4);

my $listScroll = $listFrame->Scrollbar(-orient => 'vertical');
my $listbox = $listFrame->Listbox(
    -selectmode => 'extended',
    -yscrollcommand => ['set', $listScroll],
    -font => 'Courier 9',
);
$listScroll->configure(-command => ['yview', $listbox]);
$listScroll->pack(-side => 'right', -fill => 'y');
$listbox->pack(-side => 'left', -fill => 'both', -expand => 1);

# --- status line -----------------------------------------------------------------
my $statusVar = 'No files queued.';
$mw->Label(-textvariable => \$statusVar, -anchor => 'w')
    ->pack(-side => 'top', -fill => 'x', -padx => 10);

# --- the one destructive action --------------------------------------------------
my $actionFrame = $mw->Frame->pack(-side => 'top', -fill => 'x', -padx => 10, -pady => 6);
my $stripBtn = $actionFrame->Button(
    -text => 'Remove All Metadata',
    -font => $boldFont,
    -command => \&confirm_and_strip,
    -state => 'disabled',
)->pack(-side => 'left');

# --- log output -----------------------------------------------------------------
$mw->Label(-text => 'Activity Log:', -anchor => 'w')
    ->pack(-side => 'top', -fill => 'x', -padx => 10);

my $logFrame = $mw->Frame->pack(-side => 'top', -fill => 'both', -expand => 1, -padx => 10, -pady => [0, 10]);
my $logScroll = $logFrame->Scrollbar(-orient => 'vertical');
my $logText = $logFrame->Text(
    -height => 8, -wrap => 'word', -state => 'disabled',
    -yscrollcommand => ['set', $logScroll],
);
$logScroll->configure(-command => ['yview', $logText]);
$logScroll->pack(-side => 'right', -fill => 'y');
$logText->pack(-side => 'left', -fill => 'both', -expand => 1);

#------------------------------------------------------------------------------
sub log_line {
    my ($msg) = @_;
    $logText->configure(-state => 'normal');
    $logText->insert('end', "$msg\n");
    $logText->see('end');
    $logText->configure(-state => 'disabled');
}

sub refresh_status {
    my $n = scalar @queue;
    $statusVar = $n == 0 ? 'No files queued.'
               : $n == 1 ? '1 file queued.'
               : "$n files queued.";
    $stripBtn->configure(-state => ($n && !$running) ? 'normal' : 'disabled');
}

sub add_paths {
    my @paths = @_;
    return unless @paths;
    my @newFiles = collect_files(@paths);
    my %have = map { $_ => 1 } @queue;
    my $added = 0;
    for my $f (@newFiles) {
        next if $have{$f}++;
        push @queue, $f;
        $listbox->insert('end', $f);
        $added++;
    }
    log_line("Added $added file(s) (from " . scalar(@paths) . " item(s) dropped/selected).") if $added;
    refresh_status();
}

sub add_files {
    my @files = $mw->getOpenFile(
        -title => 'Select files to add',
        -multiple => 1,
    );
    add_paths(@files) if @files;
}

sub add_folder {
    my $dir = $mw->chooseDirectory(-title => 'Select a folder to add');
    add_paths($dir) if $dir;
}

sub remove_selected {
    my @sel = $listbox->curselection;
    return unless @sel;
    # remove from highest index to lowest so indices stay valid
    for my $idx (reverse sort { $a <=> $b } @sel) {
        splice(@queue, $idx, 1);
        $listbox->delete($idx);
    }
    log_line('Removed ' . scalar(@sel) . ' item(s) from the list (not touched on disk).');
    refresh_status();
}

sub clear_list {
    return unless @queue;
    @queue = ();
    $listbox->delete(0, 'end');
    log_line('List cleared (nothing on disk was touched).');
    refresh_status();
}

sub confirm_and_strip {
    return unless @queue;
    my $n = scalar @queue;

    # Tk's built-in messageBox can't hold a checkbox, so this confirmation
    # is a small custom dialog instead. It still behaves like a normal
    # modal Yes/No prompt -- it just also carries the backup toggle.
    my $doBackup = 1;   # default to the safer choice: keep a backup
    my $answer = 'No';

    my $dlg = $mw->Toplevel(-title => 'Are you sure?');
    $dlg->transient($mw);
    $dlg->resizable(0, 0);
    $dlg->protocol('WM_DELETE_WINDOW' => sub { $answer = 'No'; $dlg->destroy; });

    $dlg->Label(
        -justify => 'left', -wraplength => 380, -anchor => 'w',
        -text =>
            "This will permanently remove ALL metadata from $n file(s).\n\n"
          . "RAW/proprietary camera formats (CR2, NEF, ARW, DNG, etc.) are "
          . "skipped automatically for safety.\n\n"
          . "This cannot be undone through this tool. Continue?",
    )->pack(-padx => 16, -pady => [16, 8], -anchor => 'w');

    $dlg->Checkbutton(
        -text => 'Keep a backup copy (named "<file>_original") before removing metadata',
        -variable => \$doBackup,
        -onvalue => 1, -offvalue => 0,
        -wraplength => 380, -justify => 'left',
    )->pack(-padx => 16, -pady => [0, 4], -anchor => 'w');

    $dlg->Label(
        -text => 'Leave unchecked and there will be no way to recover the original file.',
        -fg => 'red', -wraplength => 380, -justify => 'left', -anchor => 'w',
    )->pack(-padx => 16, -pady => [0, 12], -anchor => 'w');

    my $btnRow = $dlg->Frame->pack(-pady => [0, 16]);
    $btnRow->Button(-text => 'Yes', -width => 10, -default => 'active',
        -command => sub { $answer = 'Yes'; $dlg->destroy; },
    )->pack(-side => 'left', -padx => 6);
    $btnRow->Button(-text => 'No', -width => 10,
        -command => sub { $answer = 'No'; $dlg->destroy; },
    )->pack(-side => 'left', -padx => 6);

    $dlg->grab;
    $dlg->waitWindow;   # block here until the dialog is closed/answered

    return unless $answer eq 'Yes';
    do_strip($doBackup);
}

sub do_strip {
    my ($doBackup) = @_;
    $doBackup = 1 unless defined $doBackup;   # safe default if ever called without one

    $running = 1;
    $addFilesBtn->configure(-state => 'disabled');
    $addFolderBtn->configure(-state => 'disabled');
    $removeSelBtn->configure(-state => 'disabled');
    $clearBtn->configure(-state => 'disabled');
    $stripBtn->configure(-state => 'disabled');

    log_line('---');
    log_line('Starting metadata removal for ' . scalar(@queue) . ' file(s)... '
            . ($doBackup ? '(backups will be kept)' : '(NO backups -- overwriting in place)'));

    my $summary = strip_files(\@queue, { Backup => $doBackup, AllowUnsafe => 0 }, sub {
        my ($r, $i, $total) = @_;
        if ($r->{ok}) {
            log_line("[$i/$total] OK    $r->{path}");
        } elsif ($r->{skipped}) {
            log_line("[$i/$total] SKIP  $r->{path}  -- $r->{error}");
        } else {
            log_line("[$i/$total] FAIL  $r->{path}  -- $r->{error}");
        }
        # keep the UI responsive during a long batch
        $mw->update;
    });

    log_line('---');
    log_line("Done. $summary->{ok} stripped, $summary->{skipped} skipped, "
            . "$summary->{failed} failed (of $summary->{total}).");

    $mw->messageBox(
        -title => 'Metadata removal complete',
        -icon  => 'info',
        -type  => 'Ok',
        -message =>
            "$summary->{ok} file(s) had all metadata removed.\n"
          . "$summary->{skipped} file(s) were skipped (unsafe format).\n"
          . "$summary->{failed} file(s) failed.\n\n"
          . ($doBackup
                ? 'Backup copies ("<file>_original") were kept next to each file.'
                : 'No backups were made -- the original metadata is gone for good.')
          . "\n\nSee the activity log for details.",
    );

    $running = 0;
    $addFilesBtn->configure(-state => 'normal');
    $addFolderBtn->configure(-state => 'normal');
    $removeSelBtn->configure(-state => 'normal');
    $clearBtn->configure(-state => 'normal');
    refresh_status();
}

#------------------------------------------------------------------------------
# startup: anything dragged onto the compiled .exe icon arrives in @ARGV,
# exactly like the stock exiftool.exe drag-and-drop behaviour.
add_paths(@ARGV) if @ARGV;
refresh_status();

MainLoop();
