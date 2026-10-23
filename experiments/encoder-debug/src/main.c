#include "stm32f1xx_hal.h"

static I2C_HandleTypeDef hi2c1;

#define OLED_ADDR 0x78

static uint8_t g_activity;
static uint8_t g_levels;

static void system_clock_config(void);
static void gpio_init(void);
static void i2c1_init(void);
static void i2c_bus_recover(void);
static HAL_StatusTypeDef oled_write_cmd(uint8_t cmd);
static HAL_StatusTypeDef oled_init_sh1106(void);
static HAL_StatusTypeDef oled_draw_blocks(uint8_t activity, uint8_t levels);

void SysTick_Handler(void)
{
    HAL_IncTick();
}

int main(void)
{
    HAL_Init();
    system_clock_config();
    gpio_init();
    i2c_bus_recover();
    i2c1_init();

    if (oled_init_sh1106() != HAL_OK) {
        while (1) {
            HAL_GPIO_TogglePin(GPIOC, GPIO_PIN_13);
            HAL_Delay(100);
        }
    }

    uint8_t prev = (HAL_GPIO_ReadPin(GPIOA, GPIO_PIN_0) ? 1 : 0) |
                   (HAL_GPIO_ReadPin(GPIOA, GPIO_PIN_1) ? 2 : 0);
    uint8_t prev_button = HAL_GPIO_ReadPin(GPIOA, GPIO_PIN_3) ? 1 : 0;

    g_activity = 0;
    g_levels   = prev | (prev_button << 2);
    oled_draw_blocks(g_activity, g_levels);

    while (1) {
        uint8_t now = (HAL_GPIO_ReadPin(GPIOA, GPIO_PIN_0) ? 1 : 0) |
                      (HAL_GPIO_ReadPin(GPIOA, GPIO_PIN_1) ? 2 : 0);
        uint8_t button = HAL_GPIO_ReadPin(GPIOA, GPIO_PIN_3) ? 1 : 0;

        if ((now ^ prev) != 0 || button != prev_button) {
            g_activity ^= (now ^ prev) & 0x07;
            g_levels = now | (button << 2);
            oled_draw_blocks(g_activity, g_levels);
            prev = now;
            prev_button = button;
        }

        HAL_Delay(20);
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

    gpio.Pin = GPIO_PIN_0 | GPIO_PIN_1 | GPIO_PIN_2 | GPIO_PIN_3;
    gpio.Mode = GPIO_MODE_INPUT;
    gpio.Pull = GPIO_PULLUP;
    gpio.Speed = GPIO_SPEED_FREQ_HIGH;
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

static HAL_StatusTypeDef oled_write_cmd(uint8_t cmd)
{
    uint8_t buf[2] = {0x00, cmd};
    return HAL_I2C_Master_Transmit(&hi2c1, OLED_ADDR, buf, sizeof(buf), 100);
}

static HAL_StatusTypeDef oled_init_sh1106(void)
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
        if (oled_write_cmd(init_cmds[i]) != HAL_OK)
            return HAL_ERROR;
    }

    HAL_Delay(100);
    return oled_write_cmd(0xAF);
}

static HAL_StatusTypeDef oled_draw_blocks(uint8_t activity, uint8_t levels)
{
    uint8_t line[129];
    line[0] = 0x40;

    for (uint8_t page = 0; page < 8; page++) {
        for (uint8_t col = 0; col < 128; col++) {
            uint8_t value = 0;

            for (uint8_t block = 0; block < 6; block++) {
                if (col >= block * 21 && col <= block * 21 + 18) {
                    if (block < 3)
                        value = (activity & (1u << block)) ? 0xFF : 0x00;
                    else
                        value = (levels & (1u << (block - 3))) ? 0xFF : 0x00;
                }
            }

            if (page == 0 || page == 7)
                value = 0x00;

            line[col + 1] = value;
        }

        if (oled_write_cmd(0xB0 | page) != HAL_OK ||
            oled_write_cmd(0x02) != HAL_OK ||
            oled_write_cmd(0x10) != HAL_OK) {
            return HAL_ERROR;
        }

        if (HAL_I2C_Master_Transmit(&hi2c1, OLED_ADDR, line, sizeof(line), 100) != HAL_OK)
            return HAL_ERROR;
    }

    return HAL_OK;
}
