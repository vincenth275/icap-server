CC ?= gcc
CFLAGS ?= -O2 -fPIC -Wall -Wextra
LDFLAGS ?= -shared

# c-icap installs public headers under /usr/include/c_icap
INCLUDES ?= -I/usr/include

OUT ?= srv_rewrite_demo.so

all: $(OUT)

$(OUT): srv_rewrite_demo.c
	$(CC) $(CFLAGS) $(INCLUDES) -o $(OUT) srv_rewrite_demo.c $(LDFLAGS)

clean:
	rm -f $(OUT)
