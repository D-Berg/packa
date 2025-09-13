paket {
    name = "hello",
    version = "2.13",
    homepage = "https://www.gnu.org/software/hello/",

    source = {
        url = "https://ftp.gnu.org/gnu/hello/hello-2.13.tar.gz",
        sha256 = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    },

    build = function(ctx)
        ctx:system("./configure --prefix=" .. ctx.prefix)
        ctx:system("make")
    end,

    install = function(ctx)
        ctx:system("make install")
    end
}
