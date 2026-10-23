#include "stm32f1xx_hal.h"

static I2C_HandleTypeDef hi2c1;
static UART_HandleTypeDef huart1;

volatile uint8_t g_found_3c;
volatile uint8_t g_found_3d;
volatile uint8_t g_display_ok;

static void system_clock_config(void);
static void gpio_init(void);
static void i2c1_init(void);
static void uart1_init(void);
static void i2c_bus_recover(void);
static void uart_puts(const char *text);
static void led_boot_indicator(void);
static void led_fast_blink(void);
static void led_slow_blink(void);
static void led_double_blink(void);
static HAL_StatusTypeDef oled_write_cmd(uint16_t addr, uint8_t cmd);
static HAL_StatusTypeDef oled_init_sh1106(uint16_t addr);
static HAL_StatusTypeDef oled_draw_border(uint16_t addr);

void SysTick_Handler(void)
{
    HAL_IncTick();
}

int main(void)
{
    HAL_Init();
    system_clock_config();
    gpio_init();
    uart1_init();
    i2c_bus_recover();
    i2c1_init();

    uart_puts("\r\nSTM32 I2C scan for OLED\r\n");
    led_boot_indicator();

    g_found_3c = 0;
    g_found_3d = 0;
    g_display_ok = 0;

    if (HAL_I2C_IsDeviceReady(&hi2c1, 0x78, 3, 100) == HAL_OK) {
        g_found_3c = 1;
        uart_puts("ACK at 7-bit address 0x3C\r\n");
    }

    if (HAL_I2C_IsDeviceReady(&hi2c1, 0x7A, 3, 100) == HAL_OK) {
        g_found_3d = 1;
        uart_puts("ACK at 7-bit address 0x3D\r\n");
    }

    uint16_t oled_addr = 0;
    if (g_found_3c) {
        oled_addr = 0x78;
        uart_puts("OLED address 0x3C found\r\n");
    } else if (g_found_3d) {
        oled_addr = 0x7A;
        uart_puts("OLED address 0x3D found\r\n");
    } else {
        uart_puts("No ACK at 0x3C or 0x3D\r\n");
    }

    if (oled_addr != 0 &&
        oled_init_sh1106(oled_addr) == HAL_OK &&
        oled_draw_border(oled_addr) == HAL_OK) {
        g_display_ok = 1;
        uart_puts("OLED initialized and border drawn\r\n");
    }

    while (1) {
        if (g_display_ok) {
            led_slow_blink();
        } else if (g_found_3c || g_found_3d) {
            led_double_blink();
        } else {
            led_fast_blink();
        }
    }
}

static void system_clock_config(void)
{
    RCC_OscInitTypeDef osc = {0};
    RCC_ClkInitTypeDef clk = {0};

    osc.OscillatorType = RCC_OSCILLATORTYPE_HSI;
    osc.HSIState = RCC_HSI_ON;
    osc.HSICalibrationValue = RCC_HSICALIBRATION_DEFAULT;
    osc.PLL.PLLState = RCC_PLL_ON;
    osc.PLL.PLLSource = RCC_PLLSOURCE_HSI_DIV2;
    osc.PLL.PLLMUL = RCC_PLL_MUL9;
    HAL_RCC_OscConfig(&osc);

    clk.ClockType = RCC_CLOCKTYPE_HCLK | RCC_CLOCKTYPE_SYSCLK |
                    RCC_CLOCKTYPE_PCLK1 | RCC_CLOCKTYPE_PCLK2;
    clk.SYSCLKSource = RCC_SYSCLKSOURCE_PLLCLK;
    clk.AHBCLKDivider = RCC_SYSCLK_DIV1;
    clk.APB1CLKDivider = RCC_HCLK_DIV2;
    clk.APB2CLKDivider = RCC_HCLK_DIV1;
    HAL_RCC_ClockConfig(&clk, FLASH_LATENCY_2);
}

static void gpio_init(void)
{
    __HAL_RCC_GPIOA_CLK_ENABLE();
    __HAL_RCC_GPIOB_CLK_ENABLE();
    __HAL_RCC_GPIOC_CLK_ENABLE();

    GPIO_InitTypeDef gpio = {0};

    gpio.Pin = GPIO_PIN_13;
    gpio.Mode = GPIO_MODE_OUTPUT_PP;
    gpio.Pull = GPIO_NOPULL;
    gpio.Speed = GPIO_SPEED_FREQ_LOW;
    HAL_GPIO_Init(GPIOC, &gpio);

    HAL_GPIO_WritePin(GPIOC, GPIO_PIN_13, GPIO_PIN_SET);

    gpio.Pin = GPIO_PIN_9;
    gpio.Mode = GPIO_MODE_AF_PP;
    gpio.Speed = GPIO_SPEED_FREQ_HIGH;
    HAL_GPIO_Init(GPIOA, &gpio);

    gpio.Pin = GPIO_PIN_10;
    gpio.Mode = GPIO_MODE_INPUT;
    gpio.Pull = GPIO_PULLUP;
    HAL_GPIO_Init(GPIOA, &gpio);
}

static void i2c1_init(void)
{
    __HAL_RCC_I2C1_CLK_ENABLE();

    GPIO_InitTypeDef gpio = {0};
    gpio.Pin = GPIO_PIN_6 | GPIO_PIN_7;
    gpio.Mode = GPIO_MODE_AF_OD;
    gpio.Pull = GPIO_PULLUP;
    gpio.Speed = GPIO_SPEED_FREQ_HIGH;
    HAL_GPIO_Init(GPIOB, &gpio);

    hi2c1.Instance = I2C1;
    hi2c1.Init.ClockSpeed = 100000;
    hi2c1.Init.DutyCycle = I2C_DUTYCYCLE_2;
    hi2c1.Init.OwnAddress1 = 0;
    hi2c1.Init.AddressingMode = I2C_ADDRESSINGMODE_7BIT;
    hi2c1.Init.DualAddressMode = I2C_DUALADDRESS_DISABLE;
    hi2c1.Init.OwnAddress2 = 0;
    hi2c1.Init.GeneralCallMode = I2C_GENERALCALL_DISABLE;
    hi2c1.Init.NoStretchMode = I2C_NOSTRETCH_DISABLE;
    HAL_I2C_Init(&hi2c1);
}

static void uart1_init(void)
{
    __HAL_RCC_USART1_CLK_ENABLE();

    huart1.Instance = USART1;
    huart1.Init.BaudRate = 115200;
    huart1.Init.WordLength = UART_WORDLENGTH_8B;
    huart1.Init.StopBits = UART_STOPBITS_1;
    huart1.Init.Parity = UART_PARITY_NONE;
    huart1.Init.Mode = UART_MODE_TX_RX;
    huart1.Init.HwFlowCtl = UART_HWCONTROL_NONE;
    huart1.Init.OverSampling = UART_OVERSAMPLING_16;
    HAL_UART_Init(&huart1);
}

static void i2c_bus_recover(void)
{
    GPIO_InitTypeDef gpio = {0};

    gpio.Pin = GPIO_PIN_6 | GPIO_PIN_7;
    gpio.Mode = GPIO_MODE_OUTPUT_OD;
    gpio.Pull = GPIO_PULLUP;
    gpio.Speed = GPIO_SPEED_FREQ_HIGH;
    HAL_GPIO_Init(GPIOB, &gpio);

    HAL_GPIO_WritePin(GPIOB, GPIO_PIN_6 | GPIO_PIN_7, GPIO_PIN_SET);
    HAL_Delay(1);

    for (uint8_t i = 0; i < 9; i++) {
        HAL_GPIO_WritePin(GPIOB, GPIO_PIN_6, GPIO_PIN_RESET);
        HAL_Delay(1);
        HAL_GPIO_WritePin(GPIOB, GPIO_PIN_6, GPIO_PIN_SET);
        HAL_Delay(1);
    }

    HAL_GPIO_WritePin(GPIOB, GPIO_PIN_7, GPIO_PIN_RESET);
    HAL_Delay(1);
    HAL_GPIO_WritePin(GPIOB, GPIO_PIN_6, GPIO_PIN_SET);
    HAL_Delay(1);
    HAL_GPIO_WritePin(GPIOB, GPIO_PIN_7, GPIO_PIN_SET);
    HAL_Delay(1);
}

static void uart_puts(const char *text)
{
    while (*text) {
        HAL_UART_Transmit(&huart1, (uint8_t *)text, 1, 100);
        text++;
    }
}

static HAL_StatusTypeDef oled_write_cmd(uint16_t addr, uint8_t cmd)
{
    uint8_t buf[2] = {0x00, cmd};
    return HAL_I2C_Master_Transmit(&hi2c1, addr, buf, sizeof(buf), 100);
}

static HAL_StatusTypeDef oled_init_sh1106(uint16_t addr)
{
    static const uint8_t init_cmds[] = {
        0xAE,
        0x02,
        0x10,
        0x40,
        0xB0,
        0x81, 0xFF,
        0xA1,
        0xA6,
        0xA8, 0x3F,
        0xAD, 0x8B, 0x33,
        0xC8,
        0xD3, 0x00,
        0xD5, 0x80,
        0xD9, 0x1F,
        0xDA, 0x12,
        0xDB, 0x40
    };

    for (uint8_t i = 0; i < sizeof(init_cmds); i++) {
        if (oled_write_cmd(addr, init_cmds[i]) != HAL_OK) {
            return HAL_ERROR;
        }
    }

    HAL_Delay(100);
    return oled_write_cmd(addr, 0xAF);
}

static HAL_StatusTypeDef oled_draw_border(uint16_t addr)
{
    uint8_t line[129];
    line[0] = 0x40;

    for (uint8_t page = 0; page < 8; page++) {
        if (oled_write_cmd(addr, 0xB0 | page) != HAL_OK ||
            oled_write_cmd(addr, 0x02) != HAL_OK ||
            oled_write_cmd(addr, 0x10) != HAL_OK) {
            return HAL_ERROR;
        }

        for (uint8_t col = 0; col < 128; col++) {
            if (page == 0 || page == 7) {
                line[col + 1] = 0xFF;
            } else if (col == 0) {
                line[col + 1] = 0x01;
            } else if (col == 127) {
                line[col + 1] = 0x80;
            } else {
                line[col + 1] = 0x00;
            }
        }

        if (HAL_I2C_Master_Transmit(&hi2c1, addr, line, sizeof(line), 100) != HAL_OK) {
            return HAL_ERROR;
        }
    }

    return HAL_OK;
}

static void led_boot_indicator(void)
{
    for (uint8_t i = 0; i < 6; i++) {
        HAL_GPIO_TogglePin(GPIOC, GPIO_PIN_13);
        HAL_Delay(120);
    }
    HAL_GPIO_WritePin(GPIOC, GPIO_PIN_13, GPIO_PIN_SET);
    HAL_Delay(300);
}

static void led_fast_blink(void)
{
    HAL_GPIO_TogglePin(GPIOC, GPIO_PIN_13);
    HAL_Delay(100);
}

static void led_slow_blink(void)
{
    HAL_GPIO_TogglePin(GPIOC, GPIO_PIN_13);
    HAL_Delay(500);
}

static void led_double_blink(void)
{
    HAL_GPIO_TogglePin(GPIOC, GPIO_PIN_13);
    HAL_Delay(100);
    HAL_GPIO_TogglePin(GPIOC, GPIO_PIN_13);
    HAL_Delay(100);
    HAL_GPIO_TogglePin(GPIOC, GPIO_PIN_13);
    HAL_Delay(150);
    HAL_GPIO_TogglePin(GPIOC, GPIO_PIN_13);
    HAL_Delay(800);
}
