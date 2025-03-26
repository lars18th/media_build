This is a fork of the original CrazyCat's media_build adaptation: https://github.com/crazycat69/media_build

---

And this version includes a generic patch that integrates the firmwares inside the driver modules.
This solves the problem when your kernel (or system) does not provide the functions to load firmwares.
All firmwares available at compile time will be embedded as blobs inside the .ko files.

The solution is totally generic using three Perl scripts. You can use them for other purposes.
For example you can compile your own modules incorporating the firmware without touching the kernel.
You just need to apply the patches to the modules you want to compile.

Disclaimer: Remember that this may break licenses. Use it only when necessary.

Enjoy!
