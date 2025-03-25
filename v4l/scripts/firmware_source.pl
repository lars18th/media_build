#!/usr/bin/perl
use strict;
use warnings;
use File::Find;
use File::Copy;
use File::Basename;

# Check if the input directory is provided
if (@ARGV != 1) {
    die "Usage: $0 <source_directory>\n";
}

# Get the directory from ARGV and ensure it's an absolute path
my $source_dir = File::Spec->rel2abs($ARGV[0]);

# Ensure the directory exists
unless (-d $source_dir) {
    die "The directory $source_dir does not exist or is not accessible.\n";
}

# Function to normalize names to valid C identifiers
sub normalize_name {
    my ($name) = @_;
    $name =~ s/[-\.]/_/g;  # Replace invalid characters with underscores
    return $name;
}

# Function to process .c files
sub process_c_file {
    my $file = $File::Find::name;

    # Only process .c files
    return unless $file =~ /\.c$/;

    # Read the file content
    open my $in, '<', $file or die "Cannot read file $file: $!";
    my @lines = <$in>;
    close $in;

    # Collect included .h files and check for corresponding .h_fw files
    my @included_headers = ();
    my @fw_headers = ();
    foreach my $line (@lines) {
        if ($line =~ /^\s*#include\s+"([^"]+\.h)"/) {
            my $included_header = $1;
            push @included_headers, $included_header;

            my $header_fw_file = File::Spec->catfile($File::Find::dir, "$included_header" . "_fw");
            if (-e $header_fw_file) {
                push @fw_headers, $included_header;
            }
        }
    }

    # If no .h_fw files were found, skip this .c file silently
    if (scalar(@fw_headers) == 0) {
        return;
    }

    # If there is more than one .h_fw file, generate a warning and skip the file
    if (scalar(@fw_headers) > 1) {
        print "Warning: Multiple .h_fw files found for $file: @fw_headers\n";
        return;
    }

    # Normalize the name of the .h file
    my $fw_header = $fw_headers[0];  # We are sure there's only one at this point
    my $normalized_name = normalize_name(basename($fw_header));

    # Make a copy of the original .c file with the extension .c_fw
    my $backup_c_file = "$file" . "_fw"; # New filename for the copied .c file
    copy($file, $backup_c_file) or die "Cannot copy $file to $backup_c_file: $!";

    # First pass: Modify the content of the original .c file to replace request_firmware()
    my $modified_request = 0;  # Counter for the number of request_firmware modifications
    open my $out, '>', $file or die "Cannot write to file $file: $!";
    foreach my $line (@lines) {
        if ($line =~ s/\brequest_firmware\b/_request_firmware_$normalized_name/g) {
            $modified_request++;
        }
        print $out $line;
    }
    close $out;

    # If no modifications were made to request_firmware, delete the backup file and return
    if ($modified_request == 0) {
        unlink $backup_c_file or warn "Could not delete $backup_c_file: $!";
        print "$file: no modifications required, backup deleted\n";
        return;
    } else {
        print "$file: processed, replaced $modified_request instances with _request_firmware_$normalized_name()\n";
    }

    # Second pass: Modify the content to replace release_firmware()
    open $in, '<', $file or die "Cannot read file $file: $!";
    @lines = <$in>;  # Read the updated file content
    close $in;

    my $modified_release = 0;  # Counter for the number of release_firmware modifications
    open $out, '>', $file or die "Cannot write to file $file: $!";
    foreach my $line (@lines) {
        if ($line =~ s/\brelease_firmware\b/_release_firmware_$normalized_name/g) {
            $modified_release++;
        }
        print $out $line;
    }
    close $out;

    if ($modified_release > 0) {
        print "$file: processed, replaced $modified_release instances with _release_firmware_$normalized_name()\n";
    }
}

# Recursively traverse the source directory and process .c files
find(\&process_c_file, $source_dir);

print "Processing completed.\n";
