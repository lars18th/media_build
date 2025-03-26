#!/usr/bin/perl
use strict;
use warnings;
use File::Find;
use File::Spec;
use File::Copy;
use File::Basename;

# Check if the input directories are defined
if (@ARGV != 2) {
    die "Usage: $0 <code_directory> <firmware_headers_directory>\n";
}

# Get the directories from ARGV and ensure they are absolute paths
my $code_dir = File::Spec->rel2abs($ARGV[0]);
my $firmware_dir = File::Spec->rel2abs($ARGV[1]);

# Ensure the directories exist
unless (-d $code_dir) {
    die "The directory $code_dir does not exist or is not accessible.\n";
}
unless (-d $firmware_dir) {
    die "The directory $firmware_dir does not exist or is not accessible.\n";
}

# Regular expression to match firmware defines
# Example: #defines like '#define ????FIRMWARE???? "filename.fw"'
my $define_regex = qr/^#define\s+(\S+)\s+"([^"]+\.fw)"/;

# Template for the inline blob firmware load
my $inline_blob_template = <<"INLINE_BLOB";
/* -------* Inline BLOB for firmware DEFINE_NAME *------- */
#define DEFINE_NAME "FILENAME"
#include <linux/firmware.h>
#include "HEADER_FILE"
static inline int request_firmware_NORMALIZED_NAME(const struct firmware **fw,
                                 const char *name,
                                 struct device *device) {
    if (!strcmp(name, DEFINE_NAME)) {
        static const struct firmware embedded_fw = {
            .data = NORMALIZED_NAME_bin,
            .size = sizeof(NORMALIZED_NAME_bin),
        };
        *fw = &embedded_fw;
        pr_info("%s: blob \'%s\' loaded\\n", KBUILD_MODNAME, name);
        return 0; // Firmware found and loaded successfully
    }
    return -ENOENT; // Firmware not found
}
/* -------* End of BLOB for firmware DEFINE_NAME *------- */
INLINE_BLOB

# Template for the main firmware loading function
my $fn_end_and_request_firmware_template = <<"END_MAIN";
/* =======* Replaced firmware load function for inline blobs *======= */
static const void *blob_memory_list_NORMALIZED_FILE[] = {
BLOB_MEMORY_LIST_PLACEHOLDER
};

static inline int _request_firmware_NORMALIZED_FILE(const struct firmware **fw, const char *name, struct device *device) {
CALLS_PLACEHOLDER
    return request_firmware(fw, name, device);
}

static void _release_firmware_NORMALIZED_FILE(const struct firmware *fw) {
    if (!fw) return;
    size_t i;
    for (i = 0; i < ARRAY_SIZE(blob_memory_list_NORMALIZED_FILE); i++) {
        if (fw->data == blob_memory_list_NORMALIZED_FILE[i]) {
            pr_info("%s: blob firmware does not require release\\n", KBUILD_MODNAME);
            return;
        }
    }
    pr_info("%s: releasing dynamic firmware\\n", KBUILD_MODNAME);
    release_firmware(fw);
}
/* =======*  End of firmware load function for inline blobs  *======= */
END_MAIN

# Function to normalize names to valid C identifiers
sub normalize_name {
    my ($name) = @_;
    $name =~ s/[-\.]/_/g;  # Replace invalid characters with underscores
    return $name;
}

# Function to search for the corresponding .h file in the firmware headers directory
sub find_firmware_header {
    my ($filename) = @_;
    my @found_files;

    find(
        sub {
            if ($_ eq $filename) {
                push @found_files, $File::Find::name;
            }
        },
        $firmware_dir
    );

    return @found_files;
}

# Main: Process .h files
sub process_header_file {
    my $file = $File::Find::name;

    # Only process .h files
    return unless $file =~ /\.h$/;

    # Normalize the file name
    my $normalized_file_name = normalize_name(basename($file));

    # Get the absolute path of the file
    my $abs_file = File::Spec->rel2abs($file);

    # Read the file content
    open my $in, '<', $abs_file or die "Cannot read file $abs_file: $!";
    my @lines = <$in>;
    close $in;

    # Count the number of firmware defines
    my @defines;
    my $total_defines = 0;  # Global variable to count all #defines
    foreach my $line (@lines) {
        if ($line =~ $define_regex) {
            push @defines, [$1, $2];
            $total_defines++;
        }
    }

    # Determine whether to skip or process the file
    if ($total_defines == 0) {
        #print "$abs_file: skip\n";
        return;
    } else {
        print "$abs_file: processing...\n";
    }

    # Copy the original file with a ".h_fw" extension
    my $backup_file = $abs_file . "_fw";
    move($abs_file, $backup_file) or die "Cannot rename $abs_file to $backup_file: $!";

    # Open the original file for writing
    open my $out, '>', $abs_file or die "Cannot write to file $abs_file: $!";

    my $processed_count = 0;  # Counter for successfully replaced defines
    my $total_count = 0;  # Counter for all processed defines
    my @normalized_filenames;  # Array to store all normalized filenames
    foreach my $line (@lines) {
        chomp($line);

        # Process only lines that match the firmware define pattern
        if ($line =~ $define_regex) {
            $total_count++;
            my ($define_name, $filename) = ($1, $2);
            my $normalized_define_name = normalize_name($define_name);
            my $normalized_filename = normalize_name($filename);

            my $header_file = $filename;
            $header_file =~ s/\.fw$/.h/;

            # Search for the firmware header file using the original filename
            my @found_files = find_firmware_header($header_file);

            if (!@found_files) {
                print "-: $line: missing\n";
                print $out "$line\n";
            } else {
                my $source_header_path = $found_files[0];
                my $target_header_path = File::Spec->catfile(dirname($abs_file), $header_file);

                copy($source_header_path, $target_header_path) or die "Cannot copy $source_header_path to $target_header_path: $!";
                $processed_count++;
                push @normalized_filenames, $normalized_filename;
                print "$processed_count: $line: found\n";

                # Write the modified block for the define
                my $blob = $inline_blob_template;
                $blob =~ s/DEFINE_NAME/$normalized_define_name/g;
                $blob =~ s/FILENAME/$filename/g;
                $blob =~ s/NORMALIZED_NAME/$normalized_filename/g;
                $blob =~ s/HEADER_FILE/$header_file/g;
                print $out $blob;
            }

            # Add the request_firmware() block after the last replaced define
            if ($total_count >= $total_defines && $processed_count > 0) {
                my $calls = '';
                foreach my $name (@normalized_filenames) {
                    $calls .= "    if (request_firmware_$name(fw, name, device) == 0) return 0;\n";
                }

                # Generate the blob memory list
                my $blob_list = join(",\n", map { "    ${_}_bin" } @normalized_filenames);

                # Replace placeholder with the generated calls
                my $final_block = $fn_end_and_request_firmware_template;
                $final_block =~ s/BLOB_MEMORY_LIST_PLACEHOLDER/$blob_list/;
                $final_block =~ s/CALLS_PLACEHOLDER/$calls/;
                $final_block =~ s/NORMALIZED_FILE/$normalized_file_name/g;

                print "*: adding new _request_firmware_$normalized_file_name() function\n";
                print $out $final_block;
            }
            next;
        }
        print $out "$line\n";
    }

    close $out;

    if ($processed_count == 0) {
        unlink $backup_file or warn "Could not delete $backup_file: $!";
        print "$abs_file: no modifications made, backup deleted\n";
    }
    print "Processed: $processed_count occurrences\n";
}

# Recursively traverse the code directory starting from the provided directory
find(\&process_header_file, $code_dir);

print "Processing completed.\n";
