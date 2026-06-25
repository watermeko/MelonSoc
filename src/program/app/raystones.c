/* A port of Dmitry Sokolov's tiny raytracer to C and to FemtoRV32 */
/* Displays on the RGB565 LCD via DDR framebuffer                   */
/* Bruno Levy, 2020                                                */
/* Original tinyraytracer: https://github.com/ssloy/tinyraytracer  */

#include <stdint.h>
// #include <math.h>
#include "gpio.h"
#include "lcd.h"
#include "timer.h"

int printf(const char *fmt, ...);

#ifndef M_PI
#define M_PI 3.14159265358979323846f
#endif

#if defined(__riscv_xlen) && __riscv_xlen == 32
static inline uint64_t rdcycle(void) {
  uint32_t hi, lo, hi_check;
  do {
    asm volatile("rdcycleh %0" : "=r"(hi));
    asm volatile("rdcycle %0" : "=r"(lo));
    asm volatile("rdcycleh %0" : "=r"(hi_check));
  } while (hi != hi_check);
  return ((uint64_t)hi_check << 32) | lo;
}

static inline uint64_t rdinstret(void) {
  uint32_t hi, lo, hi_check;
  do {
    asm volatile("rdinstreth %0" : "=r"(hi));
    asm volatile("rdinstret %0" : "=r"(lo));
    asm volatile("rdinstreth %0" : "=r"(hi_check));
  } while (hi != hi_check);
  return ((uint64_t)hi_check << 32) | lo;
}
#elif defined(__riscv_xlen) && __riscv_xlen == 64
static inline uint64_t rdcycle(void) {
  uint64_t value;
  asm volatile("rdcycle %0" : "=r"(value));
  return value;
}

static inline uint64_t rdinstret(void) {
  uint64_t value;
  asm volatile("rdinstret %0" : "=r"(value));
  return value;
}
#else
static inline uint64_t rdcycle(void) {
  return 0;
}

static inline uint64_t rdinstret(void) {
  return 0;
}
#endif

/*******************************************************************/

typedef int BOOL;

static inline float max(float x, float y) { return x>y?x:y; }
static inline float min(float x, float y) { return x<y?x:y; }

static inline float raystones_absf(float x) {
  return x < 0.0f ? -x : x;
}

static float raystones_sqrtf(float x) {
  if (x <= 0.0f) {
    return 0.0f;
  }
  float guess = x > 1.0f ? x : 1.0f;
  for (int i = 0; i < 8; ++i) {
    guess = 0.5f * (guess + x / guess);
  }
  return guess;
}

static float raystones_powf(float base, float exponent) {
  if (exponent <= 0.0f) {
    return 1.0f;
  }
  if (base <= 0.0f) {
    return 0.0f;
  }
  int32_t n = (int32_t)(exponent + 0.5f);
  if (n < 0) {
    n = 0;
  }
  float result = 1.0f;
  float b = base;
  while (n > 0) {
    if (n & 1) {
      result *= b;
    }
    b *= b;
    n >>= 1;
  }
  return result;
}

/*******************************************************************/

// If you want to adapt tinyraytracer to your own platform, there are
// mostly two macros and two functions to write:
//   graphics_width
//   graphics_height
//   graphics_init()
//   graphics_set_pixel()
//
// You can also write the following functions (or leave them empty if
// you do not need them):
//   graphics_terminate()
//   stats_begin_frame()
//   stats_begin_pixel()
//   stats_end_pixel()
//   stats_end_frame()


// Size of the screen
// Replace with your own variables or values

// Benchmark
// - graphics deactivated (else UART waiting loop gives
//   different results according to CPU freq / UART baud rate
//   ratio).
// - smaller image size (for faster run in simulation)

#define GRAPHICS_WIDTH_DEFAULT 120
#define GRAPHICS_HEIGHT_DEFAULT 60
#define GRAPHICS_WIDTH_BENCH 40
#define GRAPHICS_HEIGHT_BENCH 20

static int graphics_width;
static int graphics_height;
static int bench_run;

// Render directly to the LCD framebuffer (480x272 RGB565)
// Each 120x60 logical pixel is upscaled 4x to 480x240,
// centered vertically with 16-pixel top/bottom margins.

// Simple busy-wait: give LCD DMA time to recover between bursts
// Uses hardware timer (MMIO-based, not DDR) so DDR bus stays idle.
static void lcd_yield(void) {
    timer_delay_us(500);  // 500 µs is plenty for LCD DMA to read a full line
}

// Replace with your own stuff to initialize graphics
static inline void graphics_init(void) {
    lcd_clear(0x0000);
    timer_delay_ms(10);  // let LCD DMA fully recover after full-screen clear
    printf("Rendering to LCD...\n");
}

// Replace with your own stuff to terminate graphics or leave empty
static inline void graphics_terminate(void) {
    // LCD framebuffer stays visible — nothing to tear down
}

// Replace with your own code.
void graphics_set_pixel(int x, int y, float r, float g, float b) {
   r = max(0.0f, min(1.0f, r));
   g = max(0.0f, min(1.0f, g));
   b = max(0.0f, min(1.0f, b));
   uint8_t R = (uint8_t)(255.0f * r);
   uint8_t G = (uint8_t)(255.0f * g);
   uint8_t B = (uint8_t)(255.0f * b);
   // graphics output deactivated for bench run
   if(bench_run) {
       if(y & 1) {
	  if(x == graphics_width-1) {
	     printf("%d",y/2);
	  }
       }
       return;
   }
   // Write to LCD framebuffer with 4x upscaling
   // Render: 120x60 -> LCD: 480x240 (centered vertically on 272)
   uint16_t color = lcd_rgb565(R, G, B);
   int lcd_x0 = x * 4;
   int lcd_y0 = y * 4 + 16;  // vertical centering: (272-240)/2 = 16
   volatile uint16_t *fb = lcd_fb();
   for (int dy = 0; dy < 4; ++dy) {
       for (int dx = 0; dx < 4; ++dx) {
           int lx = lcd_x0 + dx;
           int ly = lcd_y0 + dy;
           if (lx < LCD_WIDTH && ly < LCD_HEIGHT) {
               fb[ly * LCD_WIDTH + lx] = color;
           }
       }
   }
}


// Begins statistics collection for current pixel
// Leave emtpy if not needed.
// There are these two levels because on some
// femtorv32 cores (quark, tachyon), the clock tick counter does not
// have sufficient bits and will wrap during the time taken by
// rendering a frame (up to several minutes).
static inline void stats_begin_pixel(void) {
}

// Ends statistics collection for current pixel
// Leave emtpy if not needed.
static inline void stats_end_pixel(void) {
}

// Print "fixed point" number (integer/1000)
static void printk(uint64_t kx) {
    int intpart  = (int)(kx / 1000);
    int fracpart = (int)(kx % 1000);
    printf("%d.",intpart);
    if(fracpart<100) {
	printf("0");
    }
    if(fracpart<10) {
	printf("0");
    }
    printf("%d",fracpart);
}

static uint64_t instret_start;
static uint64_t cycles_start;

// Begins statistics collection for current frame.
// Leave emtpy if not needed.
static inline void stats_begin_frame(void) {
    instret_start = rdinstret();
    cycles_start  = rdcycle();
}

// Ends statistics collection for current frame
// and displays result.
// Leave emtpy if not needed.
static inline void stats_end_frame(void) {
   graphics_terminate();
   uint64_t instret = rdinstret() - instret_start;
   uint64_t cycles = rdcycle()    - cycles_start ;
   uint64_t kCPI       = cycles*1000/instret;
   uint64_t pixels     = graphics_width * graphics_height;
   uint64_t kRAYSTONES = (pixels*1000000000)/cycles;
   printf(
       "\n%dx%d      %s     ",
       graphics_width,graphics_height,
       bench_run ?
           "no gfx output (measurement is accurate)" :
           "gfx output (measurement is NOT accurate)"
   );
   printf("CPI="); printk(kCPI); printf("     ");
   printf("RAYSTONES="); printk(kRAYSTONES);
   printf("\n");
}

// Normally you will not need to modify anything beyond that point.
/*******************************************************************/

typedef struct { float x,y,z; }   vec3;
typedef struct { float x,y,z,w; } vec4;

static inline vec3 make_vec3(float x, float y, float z) {
  vec3 V;
  V.x = x; V.y = y; V.z = z;
  return V;
}

static inline vec4 make_vec4(float x, float y, float z, float w) {
  vec4 V;
  V.x = x; V.y = y; V.z = z; V.w = w;
  return V;
}

static inline vec3 vec3_neg(vec3 V) {
  return make_vec3(-V.x, -V.y, -V.z);
}

static inline vec3 vec3_add(vec3 U, vec3 V) {
  return make_vec3(U.x+V.x, U.y+V.y, U.z+V.z);
}

static inline vec3 vec3_sub(vec3 U, vec3 V) {
  return make_vec3(U.x-V.x, U.y-V.y, U.z-V.z);
}

static inline float vec3_dot(vec3 U, vec3 V) {
  return U.x*V.x+U.y*V.y+U.z*V.z;
}

static inline vec3 vec3_scale(float s, vec3 U) {
  return make_vec3(s*U.x, s*U.y, s*U.z);
}

static inline float vec3_length(vec3 U) {
  return raystones_sqrtf(U.x*U.x+U.y*U.y+U.z*U.z);
}

static inline vec3 vec3_normalize(vec3 U) {
  return vec3_scale(1.0f/vec3_length(U),U);
}

/*************************************************************************/

typedef struct Light {
    vec3 position;
    float intensity;
} Light;

Light make_Light(vec3 position, float intensity) {
  Light L;
  L.position = position;
  L.intensity = intensity;
  return L;
}

/*************************************************************************/

typedef struct {
    float refractive_index;
    vec4  albedo;
    vec3  diffuse_color;
    float specular_exponent;
} Material;

Material make_Material(float r, vec4 a, vec3 color, float spec) {
  Material M;
  M.refractive_index = r;
  M.albedo = a;
  M.diffuse_color = color;
  M.specular_exponent = spec;
  return M;
}

Material make_Material_default(void) {
  Material M;
  M.refractive_index = 1;
  M.albedo = make_vec4(1,0,0,0);
  M.diffuse_color = make_vec3(0,0,0);
  M.specular_exponent = 0;
  return M;
}

/*************************************************************************/

typedef struct {
  vec3 center;
  float radius;
  Material material;
} Sphere;

Sphere make_Sphere(vec3 c, float r, Material M) {
  Sphere S;
  S.center = c;
  S.radius = r;
  S.material = M;
  return S;
}

BOOL Sphere_ray_intersect(Sphere* S, vec3 orig, vec3 dir, float* t0) {
  vec3 L = vec3_sub(S->center, orig);
  float tca = vec3_dot(L,dir);
  float d2 = vec3_dot(L,L) - tca*tca;
  float r2 = S->radius*S->radius;
  if (d2 > r2) return 0;
  float thc = raystones_sqrtf(r2 - d2);
  *t0       = tca - thc;
  float t1 = tca + thc;
  if (*t0 < 0) *t0 = t1;
  if (*t0 < 0) return 0;
  return 1;
}

vec3 reflect(vec3 I, vec3 N) {
  return vec3_sub(I, vec3_scale(2.f*vec3_dot(I,N),N));
}

vec3 refract(vec3 I, vec3 N, float eta_t, float eta_i /* =1.f */) {
  // Snell's law
  float cosi = -max(-1.f, min(1.f, vec3_dot(I,N)));
  // if the ray comes from the inside the object, swap the air and the media  
  if (cosi<0) return refract(I, vec3_neg(N), eta_i, eta_t); 
    float eta = eta_i / eta_t;
    float k = 1 - eta*eta*(1 - cosi*cosi);
    // k<0 = total reflection, no ray to refract.
    // I refract it anyways, this has no physical meaning
    return k<0 ? make_vec3(1,0,0)
              : vec3_add(vec3_scale(eta,I),vec3_scale((eta*cosi - raystones_sqrtf(k)),N));
}

BOOL scene_intersect(
   vec3 orig, vec3 dir, Sphere* spheres, int nb_spheres,
   vec3* hit, vec3* N, Material* material
) {
  float spheres_dist = 1e30;
  for(int i=0; i<nb_spheres; ++i) {
    float dist_i;
    if(
       Sphere_ray_intersect(&spheres[i], orig, dir, &dist_i) &&
       (dist_i < spheres_dist)
    ) {
      spheres_dist = dist_i;
      *hit = vec3_add(orig,vec3_scale(dist_i,dir));
      *N = vec3_normalize(vec3_sub(*hit, spheres[i].center));
      *material = spheres[i].material;
    }
  }
  float checkerboard_dist = 1e30;
  if (raystones_absf(dir.y)>1e-3)  {
    float d = -(orig.y+4)/dir.y; // the checkerboard plane has equation y = -4
    vec3 pt = vec3_add(orig, vec3_scale(d,dir));
    if (d>0 && raystones_absf(pt.x)<10 && pt.z<-10 && pt.z>-30 && d<spheres_dist) {
      checkerboard_dist = d;
      *hit = pt;
      *N = make_vec3(0,1,0);
      material->diffuse_color =
	(((int)(.5*hit->x+1000) + (int)(.5*hit->z)) & 1)
	             ? make_vec3(.3, .3, .3)
	             : make_vec3(.3, .2, .1);
    }
  }
  return min(spheres_dist, checkerboard_dist)<1000;
}

vec3 cast_ray(
   vec3 orig, vec3 dir, Sphere* spheres, int nb_spheres,
   Light* lights, int nb_lights, int depth /* =0 */
) {
  vec3 point,N;
  Material material = make_Material_default();
  if (
    depth>2 ||
    !scene_intersect(orig, dir, spheres, nb_spheres, &point, &N, &material)
  ) {
    float s = 0.5*(dir.y + 1.0);
    return vec3_add(
	vec3_scale(s,make_vec3(0.2, 0.7, 0.8)),
        vec3_scale(s,make_vec3(0.0, 0.0, 0.5))
    );
  }

  vec3 reflect_dir=vec3_normalize(reflect(dir, N));
  vec3 refract_dir=vec3_normalize(refract(dir,N,material.refractive_index,1));
  
  // offset the original point to avoid occlusion by the object itself 
  vec3 reflect_orig =
    vec3_dot(reflect_dir,N) < 0
               ? vec3_sub(point,vec3_scale(1e-3,N))
               : vec3_add(point,vec3_scale(1e-3,N)); 
  vec3 refract_orig =
    vec3_dot(refract_dir,N) < 0
               ? vec3_sub(point,vec3_scale(1e-3,N))
               : vec3_add(point,vec3_scale(1e-3,N));
  vec3 reflect_color = cast_ray(
       reflect_orig, reflect_dir, spheres, nb_spheres,
       lights, nb_lights, depth + 1
  );
  vec3 refract_color = cast_ray(
       refract_orig, refract_dir, spheres, nb_spheres,
       lights, nb_lights, depth + 1
  );
  
  float diffuse_light_intensity = 0, specular_light_intensity = 0;
  for (int i=0; i<nb_lights; i++) {
    vec3  light_dir = vec3_normalize(vec3_sub(lights[i].position,point));
    float light_distance = vec3_length(vec3_sub(lights[i].position,point));

    vec3 shadow_orig =
      vec3_dot(light_dir,N) < 0
                ? vec3_sub(point,vec3_scale(1e-3,N))
                : vec3_add(point,vec3_scale(1e-3,N)) ;
    // checking if the point lies in the shadow of the lights[i]
    vec3 shadow_pt, shadow_N;
    Material tmpmaterial;
    if (
       scene_intersect(
	 shadow_orig, light_dir, spheres, nb_spheres,
	 &shadow_pt, &shadow_N, &tmpmaterial
       ) && (
  	 vec3_length(vec3_sub(shadow_pt,shadow_orig)) < light_distance
	     )
    ) continue ;
    
    diffuse_light_intensity  +=
                  lights[i].intensity * max(0.f, vec3_dot(light_dir,N));
     
    float abc = max(
	           0.f, vec3_dot(vec3_neg(reflect(vec3_neg(light_dir), N)),dir)
	        );
    float def = material.specular_exponent;
    if(abc > 0.0f && def > 0.0f) {
      specular_light_intensity += raystones_powf(abc,def)*lights[i].intensity;
    }
  }
  vec3 result = vec3_scale(
      diffuse_light_intensity * material.albedo.x, material.diffuse_color
  );
  result = vec3_add(
       result, vec3_scale(specular_light_intensity * material.albedo.y,
       make_vec3(1,1,1))
  );
  result = vec3_add(result, vec3_scale(material.albedo.z, reflect_color));
  result = vec3_add(result, vec3_scale(material.albedo.w, refract_color));
  return result;
}

static inline void render_pixel(
   int i, int j, Sphere* spheres, int nb_spheres, Light* lights, int nb_lights
) {
   const float inv_tan_half_fov = 1.73205080757f; // 1 / tan(M_PI/6)
   stats_begin_pixel();
   float dir_x =  (i + 0.5) - graphics_width/2.;
   float dir_y = -(j + 0.5) + graphics_height/2.; // this flips the image.
   float dir_z = -(graphics_height * 0.5f) * inv_tan_half_fov;
   vec3 C = cast_ray(
       make_vec3(0,0,0), vec3_normalize(make_vec3(dir_x, dir_y, dir_z)),
       spheres, nb_spheres, lights, nb_lights, 0
   );
   graphics_set_pixel(i,j,C.x,C.y,C.z);
   stats_end_pixel();
}

void render(Sphere* spheres, int nb_spheres, Light* lights, int nb_lights) {
   stats_begin_frame();
   for (int j = 0; j<graphics_height; j++) { 
      for (int i = 0; i<graphics_width; i++) {
	  render_pixel(i,j  ,spheres,nb_spheres,lights,nb_lights);
      }
      // Yield after each logical row — prevents LCD DMA starvation
      if (!bench_run) lcd_yield();
   }
   if (!bench_run) timer_delay_ms(10);  // final recovery: 10ms
   stats_end_frame();
}

enum {
  nb_spheres = 4,
  nb_lights = 3
};

Sphere spheres[nb_spheres];
Light lights[nb_lights];

void init_scene(void) {
    Material ivory = make_Material(
       1.0, make_vec4(0.6,  0.3, 0.1, 0.0), make_vec3(0.4, 0.4, 0.3),   50.
    );
    Material glass = make_Material(
       1.5, make_vec4(0.0,  0.5, 0.1, 0.8), make_vec3(0.6, 0.7, 0.8),  125.
    );
    Material red_rubber = make_Material(
       1.0, make_vec4(0.9,  0.1, 0.0, 0.0), make_vec3(0.3, 0.1, 0.1),   10.
    );
    Material mirror = make_Material(
       1.0, make_vec4(0.0, 10.0, 0.8, 0.0), make_vec3(1.0, 1.0, 1.0),  142.
    );

    spheres[0] = make_Sphere(make_vec3(-3,    0,   -16), 2,      ivory);
    spheres[1] = make_Sphere(make_vec3(-1.0, -1.5, -12), 2,      glass);
    spheres[2] = make_Sphere(make_vec3( 1.5, -0.5, -18), 3, red_rubber);
    spheres[3] = make_Sphere(make_vec3( 7,    5,   -18), 4,     mirror);

    lights[0] = make_Light(make_vec3(-20, 20,  20), 1.5);
    lights[1] = make_Light(make_vec3( 30, 50, -25), 1.8);
    lights[2] = make_Light(make_vec3( 30, 20,  30), 1.7);
}

void raystones_run(void) {
    init_scene();

    graphics_init();
    gpio_set_leds(5);
    bench_run = 1;
    graphics_width  = GRAPHICS_WIDTH_BENCH;
    graphics_height = GRAPHICS_HEIGHT_BENCH;
    printf("Running without graphic output (for accurate measurement)...\n");
    render(spheres, nb_spheres, lights, nb_lights);
    gpio_set_leds(10);

    bench_run = 0;
    graphics_width = GRAPHICS_WIDTH_DEFAULT;
    graphics_height = GRAPHICS_HEIGHT_DEFAULT;
    graphics_init();
    render(spheres, nb_spheres, lights, nb_lights);
    gpio_set_leds(15);
    graphics_terminate();
}
