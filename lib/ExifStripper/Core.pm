#------------------------------------------------------------------------------
# File:         ExifStripper/Core.pm
#
# Description:  Core logic for the ExifTool Metadata Stripper.
#
#               This module deliberately supports exactly ONE operation:
#               removing all metadata from a file. It has no tag-editing,
#               tag-setting, renaming, or format-conversion capability of
#               any kind. If a future maintainer is tempted to add an
#               "edit a tag" feature here, that belongs in a different tool.
#
#               Kept free of any GUI dependency so it can be used from the
#               Tk front end (exif_metadata_stripper.pl), from a future
#               command-line front end, or exercised directly by tests.
#
# Requires:     Image::ExifTool (bundled in the sibling ../../lib directory
#               when running from this source tree, or bundled alongside
#               the packaged .exe -- see pp_build_exe.args)
#------------------------------------------------------------------------------
package ExifStripper::Core;

use strict;
use warnings;
use File::Find ();
use File::Copy ();
use Image::ExifTool ();
use Exporter 'import';

our $VERSION = '1.0';
our @EXPORT_OK = qw(collect_files strip_file strip_files);

# File extensions we refuse to touch even if selected, because ExifTool's
# own documentation warns that stripping all metadata from these can make
# the file unusable (e.g. proprietary RAW formats store data in the
# makernotes that's needed to decode the image). This is a safety guard,
# not an editing feature -- affected files are simply skipped and reported.
my %UNSAFE_EXT = map { $_ => 1 } qw(
    CR2 CR3 CRW NEF NRW ARW SRF SR2 ORF RAF RW2 PEF DNG RAW ERF MRW
    X3F 3FR IIQ MOS SRW GPR
);

#------------------------------------------------------------------------------
# Recursively collect regular files from a list of files and/or directories
# Inputs:  list of paths (files or directories)
# Returns: sorted list of unique regular file paths
sub collect_files {
    my @inputs = @_;
    my %seen;
    my @out;
    for my $path (@inputs) {
        next unless defined $path and length $path;
        if (-d $path) {
            File::Find::find({
                wanted => sub {
                    return unless -f $_;
                    my $full = $File::Find::name;
                    return if $seen{$full}++;
                    push @out, $full;
                },
                no_chdir => 1,
            }, $path);
        } elsif (-f $path) {
            push @out, $path unless $seen{$path}++;
        }
        # silently ignore anything that is neither a file nor a directory
        # (e.g. a broken symlink dropped onto the window)
    }
    return sort @out;
}

#------------------------------------------------------------------------------
# Determine whether a file's extension makes it unsafe to blanket-strip
sub is_unsafe_type {
    my ($path) = @_;
    return 0 unless $path =~ /\.([A-Za-z0-9]+)$/;
    return $UNSAFE_EXT{uc $1} ? 1 : 0;
}

#------------------------------------------------------------------------------
# Strip all metadata from a single file.
# Inputs:  0) file path
#          1) options hash ref:
#               Backup       => 1 (default) - copy original to "<file>_original"
#                                before stripping, matching stock exiftool's
#                                default safety behaviour
#               AllowUnsafe  => 0 (default) - if false, RAW-type files are
#                                skipped rather than stripped
# Returns: hash ref:
#            { path => $path, ok => 1|0, skipped => 1|0, error => $msg,
#              backup => $backupPathOrUndef, tagsRemoved => $count }
sub strip_file {
    my ($path, $opts) = @_;
    $opts ||= {};
    my $doBackup   = exists $opts->{Backup} ? $opts->{Backup} : 1;
    my $allowUnsafe = $opts->{AllowUnsafe} || 0;

    my %result = (path => $path, ok => 0, skipped => 0, error => undef,
                   backup => undef, tagsRemoved => 0);

    unless (-e $path) {
        $result{error} = 'File not found';
        return \%result;
    }
    unless (-f $path) {
        $result{error} = 'Not a regular file';
        return \%result;
    }
    unless (-w $path) {
        $result{error} = 'File is not writable';
        return \%result;
    }
    if (!$allowUnsafe && is_unsafe_type($path)) {
        $result{skipped} = 1;
        $result{error} = 'Skipped: RAW/proprietary format (removing all '
                        . 'metadata can make this file unreadable)';
        return \%result;
    }

    # count tags present before stripping, purely for the summary/log
    my $before = eval { Image::ExifTool::ImageInfo($path) } || {};
    my $beforeCount = scalar keys %$before;

    my $backupPath;
    if ($doBackup) {
        $backupPath = "${path}_original";
        unless (-e $backupPath) {
            unless (File::Copy::copy($path, $backupPath)) {
                $result{error} = "Could not create backup copy: $!";
                return \%result;
            }
            # preserve original timestamps on the backup
            my @st = stat($path);
            utime($st[8], $st[9], $backupPath) if @st;
        }
        $result{backup} = $backupPath;
    }

    my $et = Image::ExifTool->new;
    $et->Options(IgnoreMinorErrors => 1);
    my $set = $et->SetNewValue('*');   # mark ALL tags for deletion -- the
                                        # library equivalent of "-all=" on
                                        # the exiftool command line
    unless (defined $set) {
        $result{error} = $et->GetValue('Error') || 'Could not prepare removal';
        return \%result;
    }

    my $writeResult = eval { $et->WriteInfo($path) };
    if ($@ or !$writeResult) {
        my $err = $et->GetValue('Error') || $@ || 'Unknown write error';
        # restore from backup if we made one and the write failed/half-wrote
        if ($backupPath && -e $backupPath) {
            File::Copy::copy($backupPath, $path);
        }
        $result{error} = $err;
        return \%result;
    }

    my $after = eval { Image::ExifTool::ImageInfo($path) } || {};
    my $afterCount = scalar keys %$after;

    $result{ok} = 1;
    $result{tagsRemoved} = $beforeCount > $afterCount ? $beforeCount - $afterCount : 0;
    return \%result;
}

#------------------------------------------------------------------------------
# Strip metadata from a list of files, invoking an optional callback after
# each file so a GUI can update progress.
# Inputs:  0) array ref of file paths
#          1) options hash ref (same as strip_file, minus 'path')
#          2) optional coderef called as $cb->($result, $index, $total)
# Returns: hash ref summary: { total, ok, skipped, failed, results => [...] }
sub strip_files {
    my ($paths, $opts, $cb) = @_;
    my @results;
    my ($ok, $skipped, $failed) = (0, 0, 0);
    my $total = scalar @$paths;
    my $i = 0;
    for my $path (@$paths) {
        $i++;
        my $r = strip_file($path, $opts);
        push @results, $r;
        if ($r->{ok})      { $ok++ }
        elsif ($r->{skipped}) { $skipped++ }
        else               { $failed++ }
        $cb->($r, $i, $total) if $cb;
    }
    return { total => $total, ok => $ok, skipped => $skipped, failed => $failed,
             results => \@results };
}

1;

__END__

=head1 NAME

ExifStripper::Core - metadata-removal-only core logic

=head1 DESCRIPTION

This module is the entire "engine" behind the ExifTool Metadata Stripper.
It supports exactly one destructive operation (delete all metadata from a
file) plus the file/folder collection needed to find candidate files. It
does not read command-line-style tag-edit expressions, does not accept a
tag name/value to set, and does not rename or convert files. That is by
design -- see the project README for the rationale.

=cut
